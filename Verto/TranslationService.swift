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

/// 可切换的翻译引擎。后续接入自研模型与 LLM 翻译时在此扩展。
enum TranslationEngine: String, CaseIterable, Identifiable {
    case google
    case custom
    case llm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: String(localized: "谷歌翻译")
        case .custom: String(localized: "自研模型")
        case .llm: String(localized: "LLM 翻译")
        }
    }

    var subtitle: String {
        switch self {
        case .google: String(localized: "在线翻译 · 神经网络模型")
        case .custom: String(localized: "端侧离线 · 更快更私密")
        case .llm: String(localized: "自带 API Key · 更高质量")
        }
    }

    var isAvailable: Bool {
        self == .google
    }

    /// 配了中转就永远走中转；**没有"中转失败再落系统翻译"这种回退**。
    /// 那种回退会让用户在某次网络抖动时悄悄拿到一句质量完全不同的译文，
    /// 而且无从知道发生过什么——失败就该报失败，让用户重试。
    ///
    /// 系统翻译只是**未配置中转的开源构建**的兜底，让克隆仓库的人零配置也能跑起来。
    func makeService(relay: TranslationRelayConfiguration? = .fromBundle()) -> any TranslationService {
        if let relay { return TranslationRelayService(configuration: relay) }
        return AppleBackedTranslationService()
    }
}

struct TranslationRequest: Equatable {
    let text: String
    let source: Language
    let target: Language
}

struct TranslationResult: Equatable {
    let text: String
    let detectedLanguage: Language?
    let alternatives: [String]
}

enum TranslationError: LocalizedError, Equatable {
    case network
    case rateLimited
    case serverError(Int)
    case invalidResponse
    case textTooLong
    /// 中转明确拒绝，重试无用——令牌不对、API 没启用、计费没开、服务账号缺角色。
    /// `code` 是中转契约里的字符串码，`message` 是诊断用的原文。
    case rejected(code: String, message: String)
    /// 这份构建没配中转、落到系统翻译，而系统翻译此刻用不了
    /// （模拟器、iOS 17、语言包没装）。
    case systemTranslationUnavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .network: String(localized: "网络连接失败，请检查网络后重试")
        case .rateLimited: String(localized: "请求过于频繁，请稍后再试")
        case .serverError(let code): String(localized: "翻译服务暂时不可用（HTTP \(code)）")
        case .invalidResponse: String(localized: "无法解析翻译结果，请重试")
        case .textTooLong: String(localized: "文本过长，请缩短后重试")
        // 令牌不对是配置问题，把中转的英文原文摆给用户没有意义，单独给一句话。
        case .rejected("unauthorized", _):
            String(localized: "翻译服务拒绝了这次请求：这份构建的令牌无效")
        case .rejected(_, let message):
            String(localized: "翻译服务拒绝了这次请求：\(message)")
        case .systemTranslationUnavailable(let reason):
            String(localized: "系统翻译不可用：\(reason)")
        }
    }
}

/// 批量翻译流里的一条。失败用 `Result` 承载而不是让整条流抛出——
/// 一条失败不该拖垮同批的其余条目，语义与「单块失败只在该块内重试」一致。
struct TranslationBatchElement: Sendable {
    let text: String
    let result: Result<TranslationResult, TranslationError>
}

protocol TranslationService: Sendable {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult

    /// 同一语言对的多条文本一次提交，结果**按到达顺序**流出。
    ///
    /// 返回 AsyncStream 而不是数组，是因为几种实现的到达节奏不同，而调用方要的
    /// 恰好都是「到一条填一条」：中转按批请求、每批回来就吐该批，系统翻译的
    /// `translate(batch:)` 本身就是 AsyncSequence，默认实现则是并发 fan-out、
    /// 谁先回来吐谁。若改成返回数组，最慢的一条会把整页扣住。
    func translateBatch(
        _ texts: [String],
        source: Language,
        target: Language
    ) -> AsyncStream<TranslationBatchElement>
}

extension TranslationService {
    /// 没有原生批量能力的实现（罐头服务、语音路由）用这个：并发发单条。
    /// 行为与改造前的相机页一致，所以它们不必跟着改。
    func translateBatch(
        _ texts: [String],
        source: Language,
        target: Language
    ) -> AsyncStream<TranslationBatchElement> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: TranslationBatchElement?.self) { group in
                    for text in texts {
                        group.addTask {
                            do {
                                let result = try await translate(
                                    TranslationRequest(text: text, source: source, target: target)
                                )
                                return TranslationBatchElement(text: text, result: .success(result))
                            } catch is CancellationError {
                                // 取消不是失败，什么都不吐。
                                return nil
                            } catch {
                                return TranslationBatchElement(
                                    text: text,
                                    result: .failure(error as? TranslationError ?? .network)
                                )
                            }
                        }
                    }
                    for await element in group where element != nil {
                        continuation.yield(element!)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 中转的地址与令牌。值由 gitignore 掉的 `Secrets.xcconfig` 在构建时注入 Info.plist；
/// 读不到就是 nil，那份构建会落到系统翻译。
///
/// 只存主机名不存完整 URL 是因为 xcconfig 把 `//` 当注释起点，
/// 写 `https://…` 会被截成 `https:`。路径固定在代码里，本来也是契约的一部分。
struct TranslationRelayConfiguration: Equatable, Sendable {
    static let hostInfoKey = "VertoRelayHost"
    static let tokenInfoKey = "VertoRelayToken"

    let endpoint: URL
    let token: String

    init?(host: String?, token: String?) {
        let host = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty, !token.isEmpty,
              let endpoint = URL(string: "https://\(host)/v1/translate") else {
            return nil
        }
        self.endpoint = endpoint
        self.token = token
    }

    static func fromBundle(_ bundle: Bundle = .main) -> TranslationRelayConfiguration? {
        TranslationRelayConfiguration(
            host: bundle.object(forInfoDictionaryKey: hostInfoKey) as? String,
            token: bundle.object(forInfoDictionaryKey: tokenInfoKey) as? String
        )
    }
}

/// 进程内翻译缓存：同一引擎、语言对与原文直接复用结果，不再重复请求。
/// 只缓存成功结果，失败永远走重试。
@MainActor
final class TranslationMemoryCache {
    struct Key: Hashable {
        let engineID: String
        let sourceCode: String
        let targetCode: String
        let text: String
    }

    private var storage: [Key: TranslationResult] = [:]
    private var recentKeys: [Key] = []
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func result(for key: Key) -> TranslationResult? {
        guard let result = storage[key] else { return nil }
        touch(key)
        return result
    }

    func store(_ result: TranslationResult, for key: Key) {
        storage[key] = result
        touch(key)
        if storage.count > capacity, let oldest = recentKeys.first {
            recentKeys.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: Key) {
        if let index = recentKeys.firstIndex(of: key) {
            recentKeys.remove(at: index)
        }
        recentKeys.append(key)
    }
}

/// 本地演示译文，UI 测试通过 --uitest-canned-translation 注入，
/// 保持既有测试断言的固定输出。
struct CannedTranslationService: TranslationService {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let translation = cannedTranslation(
            for: request.text,
            sourceCode: request.source.code,
            target: request.target
        )
        return TranslationResult(
            text: translation,
            detectedLanguage: request.source.isAuto ? detectLanguage(of: request.text) : nil,
            alternatives: cannedAlternatives(for: request.text, translation: translation, target: request.target)
        )
    }

    private func cannedTranslation(for text: String, sourceCode: String, target: Language) -> String {
        switch (sourceCode, target.code, text) {
        case ("zh-Hans", "en", "今天的晚霞特别好看，我想和你一起去海边走走。"):
            return "The sunset is especially beautiful today — I'd love to take a walk along the beach with you."
        case ("en", "zh-Hans", "The sunset is especially beautiful today — I'd love to take a walk along the beach with you."):
            return "今天的晚霞特别好看，我想和你一起去海边走走。"
        case ("zh-Hans", "en", "你好"):
            return "Hello"
        case ("en", "zh-Hans", "Good morning"):
            return "早上好"
        case ("zh-Hans", "ja", "谢谢你的款待。"):
            return "おもてなしをありがとう。"
        default:
            return fallbackTranslation(for: text, target: target)
        }
    }

    private func fallbackTranslation(for text: String, target: Language) -> String {
        switch target.code {
        case "en":
            return String(localized: "A natural translation of “\(text)”")
        case "zh-Hans":
            return String(localized: "“\(text)” 的自然译文")
        case "ja":
            return String(localized: "「\(text)」の自然な翻訳")
        default:
            return "[\(target.nativeName)] \(text)"
        }
    }

    private func cannedAlternatives(for text: String, translation: String, target: Language) -> [String] {
        if text.contains("晚霞") && target.code == "en" {
            return [
                "Today's sunset is breathtaking — I'd love to walk along the beach with you.",
                "The evening sky looks especially beautiful today. Shall we take a walk by the sea?"
            ]
        }
        return [
            String(localized: "\(translation) (更自然)"),
            String(localized: "\(translation) (更简洁)")
        ]
    }

    private func detectLanguage(of text: String) -> Language {
        let containsCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
        return containsCJK ? .chinese : .english
    }
}
