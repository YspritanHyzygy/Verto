//
//  Copyright 2026 Yspritan
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import OSLog
import SwiftUI
import Translation

// 命名约定：本 app 自己的 @Observable 编排类也叫 TranslationSession（Models.swift），
// 会遮蔽框架同名类型——本文件里框架类型一律写全限定 Translation.TranslationSession。

/// 苹果 Translation 框架此路不通时抛出，router 捕获后走回退引擎。
struct AppleTranslationUnavailableError: Error {
    let reason: String
}

@MainActor
protocol AppleTranslating: AnyObject {
    func translate(
        _ text: String,
        source: Language,
        target: Language,
        volatilePreferred: Bool
    ) async throws -> String
}

/// 系统离线翻译（Translation 框架）供给方：
/// - iOS 26+：直接构造 `Translation.TranslationSession(installedSource:target:)`，
///   按语言对缓存；iOS 26.4+ 为 partial 重译另建 `.lowLatency` 策略的会话。
///   仅限语言包已安装（`LanguageAvailability` 预检），不做对话中下载弹窗——
///   未安装即抛不可用，由 Google 兜底（刻意的范围裁剪）。
/// - iOS 18–25：经 AppShell 根部常驻的宿主视图借 session（.translationTask 是
///   唯一入口）。session 绝不逃出 run(session:) 的作用域——视图消失或配置变化后
///   使用旧 session 会 fatalError。
/// - iOS 17.x / 模拟器：无条件不可用（苹果限制模拟器不支持翻译）。
@MainActor
@Observable
final class AppleTranslationProvider: AppleTranslating {
    /// iOS 18–25 宿主视图消费的配置；语言对变化时重建以触发新 session。
    /// 存 Any 以绕过存储属性不能挂 @available 的限制。
    private var hostConfigurationStorage: Any?
    private var hostSessionActive = false
    private var pendingWork: [PendingWork] = []
    private var workSignal: AsyncStream<Void>.Continuation?
    /// run() 的代际号：配置变化时 SwiftUI 先启动新 run 再恢复旧 run 的收尾，
    /// 过期 defer 不得清掉新 run 的信号与排队请求。
    private var runGeneration = 0
    /// iOS 26+ 直构 session 缓存（值为 Translation.TranslationSession）。
    private var directSessions: [String: Any] = [:]

    private struct PendingWork {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    @available(iOS 18.0, *)
    var hostConfiguration: Translation.TranslationSession.Configuration? {
        get { hostConfigurationStorage as? Translation.TranslationSession.Configuration }
        set { hostConfigurationStorage = newValue }
    }

    func translate(
        _ text: String,
        source: Language,
        target: Language,
        volatilePreferred: Bool
    ) async throws -> String {
#if targetEnvironment(simulator)
        throw AppleTranslationUnavailableError(reason: "模拟器不支持系统翻译")
#else
        if #available(iOS 26.0, *) {
            return try await directTranslate(text, source: source, target: target, volatilePreferred: volatilePreferred)
        }
        if #available(iOS 18.0, *) {
            return try await hostTranslate(text, source: source, target: target)
        }
        throw AppleTranslationUnavailableError(reason: "系统翻译需要 iOS 18 或以上")
#endif
    }

    /// 语言对变化时作废缓存的会话与宿主配置。
    func invalidate() {
        directSessions.removeAll()
        if #available(iOS 18.0, *) {
            hostConfiguration = nil
        }
    }

    // MARK: - iOS 26+ 直构路径

    @available(iOS 26.0, *)
    private func directTranslate(
        _ text: String,
        source: Language,
        target: Language,
        volatilePreferred: Bool
    ) async throws -> String {
        let session = try await directSession(source: source, target: target, volatilePreferred: volatilePreferred)
        do {
            return try await session.translate(text).targetText
        } catch {
            // 会话可能已作废（如 alreadyCancelled）：清缓存，本次仍按不可用处理。
            directSessions.removeValue(forKey: Self.sessionKey(source, target, volatilePreferred: volatilePreferred))
            throw error
        }
    }

    @available(iOS 26.0, *)
    private func directSession(
        source: Language,
        target: Language,
        volatilePreferred: Bool
    ) async throws -> Translation.TranslationSession {
        let key = Self.sessionKey(source, target, volatilePreferred: volatilePreferred)
        if let existing = directSessions[key] as? Translation.TranslationSession {
            return existing
        }
        let status = await LanguageAvailability().status(from: source.localeLanguage, to: target.localeLanguage)
        guard status == .installed else {
            let reason = status == .supported ? "语言包未安装" : "语言对不受支持"
            throw AppleTranslationUnavailableError(reason: reason)
        }
        let session: Translation.TranslationSession
        if #available(iOS 26.4, *), volatilePreferred {
            session = Translation.TranslationSession(
                installedSource: source.localeLanguage,
                target: target.localeLanguage,
                preferredStrategy: .lowLatency
            )
        } else {
            session = Translation.TranslationSession(
                installedSource: source.localeLanguage,
                target: target.localeLanguage
            )
        }
        directSessions[key] = session
        return session
    }

    private static func sessionKey(_ source: Language, _ target: Language, volatilePreferred: Bool) -> String {
        "\(source.code)>\(target.code)#\(volatilePreferred ? "lowLatency" : "standard")"
    }

    // MARK: - iOS 18–25 宿主路径

    /// 宿主视图的 translationTask 回调：在 run 的作用域内消费请求队列。
    /// task 被取消（配置变化/视图消失）时，未完成项全部以取消收尾。
    @available(iOS 18.0, *)
    func run(_ session: Translation.TranslationSession) async {
        runGeneration += 1
        let generation = runGeneration
        let (signals, signal) = AsyncStream.makeStream(of: Void.self)
        workSignal = signal
        hostSessionActive = true
        defer {
            // 只有仍是最新一代时才收尾；过期 run 的 defer 不碰新 run 的状态。
            if generation == runGeneration {
                hostSessionActive = false
                workSignal = nil
                for item in pendingWork {
                    item.continuation.resume(throwing: CancellationError())
                }
                pendingWork.removeAll()
            }
        }
        signal.yield()
        for await _ in signals {
            while !pendingWork.isEmpty {
                guard !Task.isCancelled else { return }
                let item = pendingWork.removeFirst()
                do {
                    let response = try await session.translate(item.text)
                    item.continuation.resume(returning: response.targetText)
                } catch {
                    item.continuation.resume(throwing: error)
                }
            }
            if Task.isCancelled { return }
        }
    }

    @available(iOS 18.0, *)
    private func hostTranslate(_ text: String, source: Language, target: Language) async throws -> String {
        let desired = Translation.TranslationSession.Configuration(
            source: source.localeLanguage,
            target: target.localeLanguage
        )
        if hostConfiguration?.source != desired.source || hostConfiguration?.target != desired.target {
            hostConfiguration = desired
            // 换语言对后必须等新 session 就绪，不能把请求塞给旧语言对的 run。
            hostSessionActive = false
        }
        // 等宿主 session 就绪（最多 3 秒），拿不到就按不可用回退。
        var waited: Duration = .zero
        while !hostSessionActive, waited < .seconds(3) {
            try? await Task.sleep(for: .milliseconds(100))
            waited += .milliseconds(100)
        }
        guard hostSessionActive else {
            throw AppleTranslationUnavailableError(reason: "宿主翻译会话未就绪")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingWork.append(PendingWork(text: text, continuation: continuation))
            workSignal?.yield()
        }
    }
}

/// 常驻 AppShell 根部的 1pt 宿主视图（iOS 18–25 路径的 session 来源）。
/// 必须保持"在层级中且可见"——.hidden() 会让 translationTask 不触发；
/// 挂在根部、跨 tab 不销毁，是 stale-session fatalError 的防线。
@available(iOS 18.0, *)
struct AppleTranslationHostView: View {
    @Bindable var provider: AppleTranslationProvider

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(provider.hostConfiguration) { session in
                await provider.run(session)
            }
    }
}

/// 语音页翻译路由：苹果 Translation 优先；同一语言对首次失败后本会话内
/// 记忆决策直接走回退引擎，避免 350ms 一次的 partial 重译反复撞墙。
@MainActor
final class VoiceTranslationRouter: TranslationService, VolatileTranslationSupporting {
    private let apple: (any AppleTranslating)?
    private let fallback: any TranslationService
    private let onEngineDecision: (@MainActor (String) -> Void)?
    private var applePairFailures: Set<String> = []
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Verto",
        category: "VoiceTranslation"
    )

    init(
        apple: (any AppleTranslating)?,
        fallback: any TranslationService,
        onEngineDecision: (@MainActor (String) -> Void)? = nil
    ) {
        self.apple = apple
        self.fallback = fallback
        self.onEngineDecision = onEngineDecision
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try await route(request, volatilePreferred: false)
    }

    func translateVolatile(_ request: TranslationRequest) async throws -> TranslationResult {
        try await route(request, volatilePreferred: true)
    }

    /// 语言切换等时机可重试苹果路径。
    func resetPairMemos() {
        applePairFailures.removeAll()
    }

    private func route(_ request: TranslationRequest, volatilePreferred: Bool) async throws -> TranslationResult {
        let pairKey = "\(request.source.code)>\(request.target.code)"
        if let apple, !applePairFailures.contains(pairKey) {
            do {
                let text = try await apple.translate(
                    request.text,
                    source: request.source,
                    target: request.target,
                    volatilePreferred: volatilePreferred
                )
                onEngineDecision?("apple")
                return TranslationResult(text: text, detectedLanguage: nil, alternatives: [])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                applePairFailures.insert(pairKey)
                logger.info("系统翻译不可用，语言对 \(pairKey, privacy: .public) 本会话改用回退引擎：\(String(describing: error), privacy: .public)")
                onEngineDecision?("google:\(String(describing: error))")
            }
        } else {
            onEngineDecision?(apple == nil ? "google:no-apple" : "google:pair-memo")
        }
        return try await fallback.translate(request)
    }
}

// MARK: - 未来流式引擎接缝（Gemini live-translate 等，只留缝不实现）
//
// Gemini 3.5 Live Translate（gemini-3.5-live-translate-preview，Gemini Live API
// 公开预览）的形状是「音频流进 → 译文音频 + 双语增量文本出」（WebSocket，
// PCM16/16kHz 进、PCM16/24kHz 出），与 text→text 的 TranslationService 不同层。
// 接入时实现下面的协议、整体替换 VoiceConversationController.runUtterance()
// 里「ASR 事件流 + 翻译 router」的组合；采集侧 MicrophoneAudioSource 可加一路
// 16kHz PCM16 转换输出。鉴权经异步 TokenProvider 注入（后端换发 ephemeral
// token，客户端直连 WebSocket）。语义差异备忘：Gemini 转录为增量追加，
// Apple ASR 为 partial/final 整段替换，适配层需归一化成 isFinal 语义。
//
// protocol StreamingSpeechTranslating: Sendable {
//     func start(source: Language, target: Language) async throws
//     func send(_ audio: AVAudioPCMBuffer) async
//     var events: AsyncThrowingStream<StreamingSpeechTranslationEvent, Error> { get }
//     func finish() async
// }
//
// enum StreamingSpeechTranslationEvent: Sendable {
//     case sourceTranscript(String, isFinal: Bool)
//     case translation(String, isFinal: Bool)
//     case translatedAudio(Data)   // PCM16 24kHz
// }
//
// protocol StreamingTranslationTokenProvider: Sendable {
//     func ephemeralToken() async throws -> String
// }
