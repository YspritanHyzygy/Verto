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

import AVFoundation
import Foundation
import Observation
import SwiftUI

/// 语音对话页的状态机：端点检测、部分重译节流、final 提交、TTS 门控都在这里。
/// 连续识别模型——识别链跨句持续运转，定稿即上屏、权威翻译按 turn 异步填充，
/// 识别永不等翻译；自动朗读排队在无人说话的间隙播放，播放时挂起识别输入防回采。
@Observable
@MainActor
final class VoiceConversationController {
    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case finalizing
        case speaking
        case failed(Failure)
    }

    enum Failure: Equatable {
        /// 权限被拒：状态区附「前往设置」。
        case permissionDenied(message: String)
        case other(message: String)

        var message: String {
            switch self {
            case .permissionDenied(let message),
                 .other(let message):
                message
            }
        }
    }

    struct LiveUtterance: Equatable {
        var speaker: ConversationTurn.Speaker
        var languageName: String
        var original: String = ""
        var translation: String = ""
        var isFinal = false
    }

    /// 聆听模式：auto = 语言对内双轨自动检测（中间麦克风的默认体验）；
    /// manual = 锁定某一侧语言（点语言圆钮，再点一次回到自动）。
    enum ListeningMode: Equatable {
        case auto
        case manual(ConversationTurn.Speaker)
    }

    /// 测试注入的时间参数，替代 fake clock。
    struct Timing {
        var partialThrottle: Duration = VoiceTuning.partialTranslationThrottle
        var endpointVolatileStability: TimeInterval = VoiceTuning.endpointVolatileStability
        var endpointSilenceDuration: TimeInterval = VoiceTuning.endpointSilenceDuration
        var maxUtteranceDuration: TimeInterval = VoiceTuning.maxUtteranceDuration
        var noSpeechAutoPause: TimeInterval = VoiceTuning.noSpeechAutoPause
        var endpointTick: TimeInterval = 0.05
    }

    private(set) var phase: Phase = .idle
    private(set) var turns: [ConversationTurn] = []
    private(set) var live: LiveUtterance?
    private(set) var audioLevel: Float = 0
    private(set) var assetDownloadProgress: Double?
    private(set) var activeSpeaker: ConversationTurn.Speaker = .source
    private(set) var listeningMode: ListeningMode = .auto
    private(set) var voiceSource: Language = .english
    private(set) var voiceTarget: Language = .chinese
    private(set) var conversationTask: Task<Void, Never>?

    private let settings: AppSettings
    private let transcriptionFactory: @MainActor () async -> any VoiceTranscriptionService
    private let translationService: any TranslationService
    private let synthesizer: any SpeechSynthesizing
    private let headphonesConnected: @MainActor () -> Bool
    private let timing: Timing
    private let finalCache = TranslationMemoryCache()

    private var service: (any VoiceTranscriptionService)?
    private var preparedLanguageCodes: Set<String> = []
    private var userRequestedPause = false
    private var hasEverListened = false
    private var queuedMode: ListeningMode?
    private var currentPartialSourceCode: String?
    /// 权威翻译按 turn 异步进行——识别不等翻译（live translate 的关键）。
    private var turnTranslationTasks: [UUID: Task<Void, Never>] = [:]
    /// 自动朗读排队：等无人说话的间隙再播，播时挂起识别输入防回采。
    private var pendingAutoSpeech: [(text: String, languageCode: String)] = []
    private var isAutoSpeaking = false
    /// 会话循环的代际号：过期循环的收尾不得触碰新循环的状态。
    private var loopGeneration = 0
    /// 朗读代际号：过期的播放完成回调不得把新状态改回 idle。
    private var speakGeneration = 0
    /// hardStop 发出的异步 service.cancel；新一段开始前必须等它落地，
    /// 否则旧收尾可能清掉新一段的识别状态。
    private var pendingServiceCancel: Task<Void, Never>?

    private var utteranceStartedAt: Date?
    private var lastVolatileChangeAt: Date?
    private var lastVoiceActivityAt: Date?
    private var endpointRequested = false

    private var partialTask: Task<Void, Never>?
    private var needsAnotherPartial = false
    private var partialGeneration = 0
    private var lastTranslatedMasked = ""

    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    init(
        settings: AppSettings,
        transcriptionFactory: @escaping @MainActor () async -> any VoiceTranscriptionService,
        translationService: any TranslationService,
        synthesizer: (any SpeechSynthesizing)? = nil,
        headphonesConnected: (@MainActor () -> Bool)? = nil,
        timing: Timing = Timing()
    ) {
        self.settings = settings
        self.transcriptionFactory = transcriptionFactory
        self.translationService = translationService
        self.synthesizer = synthesizer ?? SystemSpeechSynthesizer()
        self.headphonesConnected = headphonesConnected ?? { AudioRouteMonitor.headphonesConnected }
        self.timing = timing

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: raw) == .began
            else { return }
            MainActor.assumeIsolated { self?.hardStop() }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - 语言

    /// 语音页语言约定沿用 AppShell 的换位：source 侧圆钮 = voiceSource。
    /// 语言对变化会丢弃进行中的一段话。
    func setLanguages(source: Language, target: Language) {
        let resolvedSource = source.resolvedForVoice(counterpart: target)
        let resolvedTarget = target.resolvedForVoice(counterpart: resolvedSource)
        guard resolvedSource != voiceSource || resolvedTarget != voiceTarget else { return }
        voiceSource = resolvedSource
        voiceTarget = resolvedTarget
        if conversationTask != nil || live != nil {
            hardStop()
        }
    }

    /// 当前讲话方使用的语言（自动模式下为最近检测到的一方）。
    var speakingLanguage: Language {
        language(for: activeSpeaker)
    }

    /// 当前讲话方的译文语言。
    var listeningLanguage: Language {
        counterpart(of: speakingLanguage)
    }

    /// 本段识别的候选语言：自动 = 语言对双轨，手动 = 锁定的一侧。
    var utteranceLanguages: [Language] {
        switch listeningMode {
        case .auto:
            voiceSource.code == voiceTarget.code ? [voiceSource] : [voiceSource, voiceTarget]
        case .manual(let speaker):
            [language(for: speaker)]
        }
    }

    private func language(for speaker: ConversationTurn.Speaker) -> Language {
        speaker == .source ? voiceSource : voiceTarget
    }

    private func speaker(for language: Language) -> ConversationTurn.Speaker {
        // 手动锁定时侧别归属跟随锁定方——语言对两侧同码时按语言码
        // 反推会把 target 锁误判成 source。
        if case .manual(let locked) = listeningMode { return locked }
        return language.code == voiceSource.code ? .source : .target
    }

    private func counterpart(of language: Language) -> Language {
        if case .manual(let locked) = listeningMode {
            return self.language(for: locked == .source ? .target : .source)
        }
        return language.code == voiceSource.code ? voiceTarget : voiceSource
    }

    // MARK: - 状态展示

    var statusText: String {
        switch phase {
        case .idle:
            hasEverListened ? String(localized: "已暂停 · 轻点继续") : String(localized: "轻点开始对话")
        case .preparing:
            if let progress = assetDownloadProgress, progress < 1 {
                String(localized: "正在下载语言模型 \(Int(progress * 100))%")
            } else {
                String(localized: "正在准备语音识别…")
            }
        case .listening:
            switch listeningMode {
            case .auto:
                String(localized: "正在聆听 · \(voiceSource.nativeName) / \(voiceTarget.nativeName)")
            case .manual:
                String(localized: "正在聆听 · \(speakingLanguage.nativeName)")
            }
        case .finalizing:
            String(localized: "正在翻译…")
        case .speaking:
            String(localized: "正在朗读…")
        case .failed(let failure):
            failure.message
        }
    }

    var isListeningActive: Bool {
        phase == .listening
    }

    var isPermissionFailure: Bool {
        if case .failed(.permissionDenied) = phase { return true }
        return false
    }

    // MARK: - 用户操作

    func toggleListening() {
        switch phase {
        case .idle, .failed:
            startListening()
        case .listening:
            userStop()
        case .speaking:
            synthesizer.stop()
        case .preparing, .finalizing:
            break
        }
    }

    func startListening() {
        guard conversationTask == nil else { return }
        if case .failed = phase {
            live = nil
        }
        userRequestedPause = false
        hasEverListened = true
        // 立即离开 failed/idle 展示态，避免旧错误文案在准备期间残留。
        phase = .preparing
        loopGeneration += 1
        let generation = loopGeneration
        conversationTask = Task { [weak self] in
            await self?.runConversationLoop(generation: generation)
            // 过期循环（已被 hardStop 换代）不得清掉新循环的句柄。
            if let self, self.loopGeneration == generation {
                self.conversationTask = nil
            }
        }
    }

    /// 语言圆钮：点另一侧 = 手动锁定该语言；再点已锁定的一侧 = 回到自动检测。
    func switchSpeaker(to speaker: ConversationTurn.Speaker) {
        let targetMode: ListeningMode
        if case .manual(let current) = listeningMode, current == speaker {
            targetMode = .auto
        } else {
            targetMode = .manual(speaker)
        }
        switch phase {
        case .idle, .failed:
            apply(mode: targetMode)
            if case .failed = phase {
                live = nil
                phase = .idle
            }
            startListening()
        case .listening:
            if let live, !live.original.isEmpty {
                // 先把这句话定稿提交，切换在提交后生效。
                queuedMode = targetMode
                requestEndpoint()
            } else {
                apply(mode: targetMode)
                restartConversation()
            }
        case .speaking where conversationTask == nil:
            // 手动气泡朗读期间没有会话循环消费队列：直接切换并给出高亮反馈。
            apply(mode: targetMode)
        case .preparing, .finalizing, .speaking:
            queuedMode = targetMode
        }
    }

    private func apply(mode: ListeningMode) {
        listeningMode = mode
        if case .manual(let speaker) = mode {
            activeSpeaker = speaker
        }
    }

    /// 重试某条已提交气泡的失败译文（识别与对话完全不受影响）。
    func retryTranslation(for turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              turns[index].translationFailed else { return }
        let turn = turns[index]
        let source = language(for: turn.speaker)
        let target = language(for: turn.speaker == .source ? .target : .source)
        updateTurn(turnID) {
            $0.translationFailed = false
            $0.isTranslationPending = true
        }
        beginAuthoritativeTranslation(turnID: turnID, text: turn.original, source: source, target: target)
    }

    /// 气泡上的朗读按钮：为避免麦克风拾取 TTS，先暂停对话再播放。
    /// finalizing/preparing 期间不可用——hardStop 会杀掉正在定稿的句子。
    func speak(_ turn: ConversationTurn) {
        guard let code = turn.translationLanguageCode ?? inferredLanguageCode(for: turn),
              !turn.translation.isEmpty else { return }
        switch phase {
        case .preparing, .finalizing:
            return
        case .idle, .listening, .speaking, .failed:
            break
        }
        hardStop()
        phase = .speaking
        speakGeneration += 1
        let generation = speakGeneration
        Task { [weak self] in
            guard let self else { return }
            await self.synthesizer.speak(turn.translation, languageCode: code)
            // 连点第二次会经 hardStop 换代：过期完成不得把新播放改回 idle。
            if self.speakGeneration == generation, self.phase == .speaking {
                self.phase = .idle
            }
        }
    }

    func handleScenePhase(_ newPhase: ScenePhase) {
        if newPhase == .background {
            hardStop()
        }
    }

    /// 切走 tab：停止收音与朗读。对话内容保留（controller 由 AppShell 持有）。
    func tearDown() {
        hardStop()
    }

    // MARK: - 主循环

    private func runConversationLoop(generation: Int) async {
        // 上一段的异步 cancel 必须先落地，否则旧收尾会清掉新一段的识别状态。
        await pendingServiceCancel?.value
        pendingServiceCancel = nil
        while !Task.isCancelled && !userRequestedPause && loopGeneration == generation {
            if let queued = queuedMode {
                apply(mode: queued)
                queuedMode = nil
            }
            let languages = utteranceLanguages
            do {
                try await prepareIfNeeded(for: languages)
            } catch {
                fail(with: error)
                return
            }
            guard !Task.isCancelled && !userRequestedPause && loopGeneration == generation else { break }
            // 准备期（权限弹窗/模型下载）用户切了模式：回到循环顶部重新取语言集。
            if queuedMode != nil { continue }
            let shouldContinue = await runUtterance(languages: languages)
            guard shouldContinue else { return }
            if let queued = queuedMode {
                apply(mode: queued)
                queuedMode = nil
            }
        }
        if !Task.isCancelled && loopGeneration == generation {
            phase = .idle
        }
    }

    private func prepareIfNeeded(for languages: [Language]) async throws {
        if service == nil {
            phase = .preparing
            service = await transcriptionFactory()
        }
        guard let service else { throw SpeechTranscriptionError.recognitionFailed }
        guard languages.contains(where: { !preparedLanguageCodes.contains($0.code) }) else { return }
        phase = .preparing
        try await service.prepare(for: languages) { [weak self] progress in
            self?.assetDownloadProgress = progress
        }
        assetDownloadProgress = nil
        languages.forEach { preparedLanguageCodes.insert($0.code) }
    }

    /// 返回值表示会话循环是否继续（失败路径为 false，phase 已就位）。
    private func runUtterance(languages: [Language]) async -> Bool {
        guard let service else { return false }
        live = nil
        audioLevel = 0
        lastTranslatedMasked = ""
        currentPartialSourceCode = nil
        endpointRequested = false
        utteranceStartedAt = Date()
        lastVolatileChangeAt = nil
        lastVoiceActivityAt = nil

        let stream: AsyncThrowingStream<SpeechTranscriptionEvent, Error>
        do {
            stream = try await service.startUtterance(languages: languages)
        } catch {
            fail(with: error)
            return false
        }
        phase = .listening
        // 上一句在 finalizing 期间完成的翻译，其朗读在此补位播放。
        drainAutoSpeech()

        let endpointMonitor = startEndpointMonitor(service: service)
        defer {
            endpointMonitor.cancel()
            cancelPartialTranslation()
            audioLevel = 0
        }

        do {
            for try await event in stream {
                switch event {
                case .audioLevel(let level):
                    audioLevel = audioLevel * 0.7 + level * 0.3
                    if level > VoiceTuning.endpointSilenceRMSThreshold {
                        lastVoiceActivityAt = Date()
                    }
                case .volatile(let text, let detected):
                    handleVolatile(text, detected: detected)
                case .final(let text, let detected):
                    return await handleFinal(text, detected: detected)
                }
            }
            // 流未产出 final 即结束（cancel 路径）；是否继续由主循环的暂停位决定。
            live = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            fail(with: error)
            return false
        }
    }

    private func handleVolatile(_ text: String, detected: Language) {
        let detectedSpeaker = speaker(for: detected)
        if live == nil {
            live = LiveUtterance(speaker: detectedSpeaker, languageName: detected.nativeName)
        } else if live?.speaker != detectedSpeaker {
            // 自动检测的胜者切换：气泡侧别与语言标签跟随。
            live?.speaker = detectedSpeaker
            live?.languageName = detected.nativeName
        }
        activeSpeaker = detectedSpeaker
        guard live?.original != text else { return }
        live?.original = text
        lastVolatileChangeAt = Date()
        lastVoiceActivityAt = Date()
        // 检测语言（翻译方向）变化时作废旧方向的部分译文。
        if currentPartialSourceCode != detected.code {
            currentPartialSourceCode = detected.code
            cancelPartialTranslation()
            lastTranslatedMasked = ""
            live?.translation = ""
        }
        schedulePartialTranslation(source: detected, target: counterpart(of: detected))
    }

    private func handleFinal(_ text: String, detected: Language) async -> Bool {
        cancelPartialTranslation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 没说出内容：静默丢弃；是否续听由主循环的暂停位决定。
            live = nil
            drainAutoSpeech()
            return true
        }
        let detectedSpeaker = speaker(for: detected)
        let target = counterpart(of: detected)
        if live == nil {
            live = LiveUtterance(speaker: detectedSpeaker, languageName: detected.nativeName)
        }
        live?.speaker = detectedSpeaker
        live?.languageName = detected.nativeName
        activeSpeaker = detectedSpeaker
        live?.original = trimmed
        live?.isFinal = true
        // final 重打分可能推翻 volatile 期的胜者：方向变了就清掉旧方向的粗译，
        // 不能让它在权威翻译往返期间（或失败重试态）继续挂在气泡里。
        if currentPartialSourceCode != detected.code {
            currentPartialSourceCode = detected.code
            lastTranslatedMasked = ""
            live?.translation = ""
        }

        // 定稿立即上屏（带粗译预览与「翻译中」态），权威翻译异步填充——
        // 识别不等翻译，主循环立刻转入下一句（live translate 的关键）。
        var turn = ConversationTurn(
            speaker: live?.speaker ?? detectedSpeaker,
            language: detected.nativeName,
            original: trimmed,
            translation: live?.translation ?? "",
            translationLanguageCode: target.speechLocaleIdentifier
        )
        turn.isTranslationPending = true
        live = nil
        turns.append(turn)
        beginAuthoritativeTranslation(turnID: turn.id, text: trimmed, source: detected, target: target)
        drainAutoSpeech()
        return true
    }

    // MARK: - 异步权威翻译与自动朗读

    private func beginAuthoritativeTranslation(
        turnID: UUID,
        text: String,
        source: Language,
        target: Language
    ) {
        turnTranslationTasks[turnID] = Task { [weak self] in
            guard let self else { return }
            defer { self.turnTranslationTasks[turnID] = nil }
            do {
                let result = try await self.translateFinal(text, source: source, target: target)
                guard !Task.isCancelled else { return }
                self.updateTurn(turnID) {
                    $0.translation = result.text
                    $0.isTranslationPending = false
                    $0.translationFailed = false
                }
                self.enqueueAutoSpeak(result.text, languageCode: target.speechLocaleIdentifier)
            } catch is CancellationError {
                self.updateTurn(turnID) {
                    if $0.isTranslationPending {
                        $0.isTranslationPending = false
                        $0.translationFailed = true
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.updateTurn(turnID) {
                    $0.isTranslationPending = false
                    $0.translationFailed = true
                }
            }
        }
    }

    private func updateTurn(_ id: UUID, _ mutate: (inout ConversationTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        var turn = turns[index]
        mutate(&turn)
        turns[index] = turn
    }

    private func enqueueAutoSpeak(_ text: String, languageCode: String) {
        let shouldSpeak: Bool
        switch settings.voicePlaybackMode {
        case .textOnly:
            shouldSpeak = false
        case .speakAfterTranslation:
            shouldSpeak = true
        case .speakOnlyWithHeadphones:
            shouldSpeak = headphonesConnected()
        }
        guard shouldSpeak else { return }
        pendingAutoSpeech.append((text, languageCode))
        drainAutoSpeech()
    }

    /// 排队朗读：等无人说话的间隙播放，播放期间挂起识别输入防回采；
    /// 用户暂停/离开时清空队列。
    private func drainAutoSpeech() {
        guard !isAutoSpeaking, !pendingAutoSpeech.isEmpty else { return }
        guard !userRequestedPause, phase == .listening || phase == .idle else {
            if userRequestedPause { pendingAutoSpeech.removeAll() }
            return
        }
        // 有人正在说话：等这句提交时再来（handleFinal 会再调 drain）。
        guard live?.original.isEmpty != false else { return }
        let item = pendingAutoSpeech.removeFirst()
        isAutoSpeaking = true
        Task { [weak self] in
            guard let self else { return }
            self.service?.setInputSuspended(true)
            await self.synthesizer.speak(item.text, languageCode: item.languageCode)
            self.service?.setInputSuspended(false)
            self.isAutoSpeaking = false
            self.drainAutoSpeech()
        }
    }

    // MARK: - 端点检测

    private func requestEndpoint() {
        guard !endpointRequested, let service else { return }
        endpointRequested = true
        // 不切相位：定稿只是识别流上的切分点，按钮与状态保持「正在聆听」，
        // 避免每句结束都闪一下转圈/「正在翻译…」。
        Task { await service.finishUtterance() }
    }

    private func startEndpointMonitor(service: any VoiceTranscriptionService) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.timing.endpointTick ?? 0.05))
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .listening, !self.endpointRequested else { continue }
                let now = Date()
                guard let startedAt = self.utteranceStartedAt else { continue }

                if self.live == nil || self.live?.original.isEmpty != false {
                    if now.timeIntervalSince(startedAt) >= self.timing.noSpeechAutoPause {
                        // 状态先落地、cancel 异步跟随（与 hardStop 同款），
                        // 避免挂起期间用户新交互被这里的回写覆盖。
                        self.userRequestedPause = true
                        self.conversationTask?.cancel()
                        self.conversationTask = nil
                        self.live = nil
                        self.phase = .idle
                        self.pendingServiceCancel = Task { await service.cancel() }
                        return
                    }
                    continue
                }

                if now.timeIntervalSince(startedAt) >= self.timing.maxUtteranceDuration {
                    self.requestEndpoint()
                    return
                }

                let volatileStable = self.lastVolatileChangeAt.map {
                    now.timeIntervalSince($0) >= self.timing.endpointVolatileStability
                } ?? false
                let silent = self.lastVoiceActivityAt.map {
                    now.timeIntervalSince($0) >= self.timing.endpointSilenceDuration
                } ?? true
                if volatileStable && silent {
                    self.requestEndpoint()
                    return
                }
            }
        }
    }

    // MARK: - 部分重译

    private func schedulePartialTranslation(source: Language, target: Language) {
        guard partialTask == nil else {
            needsAnotherPartial = true
            return
        }
        partialGeneration += 1
        let generation = partialGeneration
        partialTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 被 cancel+重排（方向翻转）换代的旧任务：不得清掉新任务的句柄，
                    // 否则单在途节流失效、后续 volatile 会并发重复请求。
                    guard generation == self.partialGeneration else { return }
                    self.partialTask = nil
                    if self.needsAnotherPartial {
                        self.needsAnotherPartial = false
                        if self.live != nil, self.live?.isFinal == false {
                            self.schedulePartialTranslation(source: source, target: target)
                        }
                    }
                }
            }
            guard let self else { return }
            try? await Task.sleep(for: self.timing.partialThrottle)
            guard !Task.isCancelled else { return }
            guard let live = self.live, !live.isFinal else { return }

            let masked = Self.maskedSource(live.original)
            guard masked.count >= 2 else { return }
            let normalized = Self.normalized(masked)
            guard normalized != self.lastTranslatedMasked else { return }

            let request = TranslationRequest(text: masked, source: source, target: target)
            guard let result = try? await self.volatileTranslate(request) else { return }
            guard generation == self.partialGeneration,
                  !Task.isCancelled,
                  self.live != nil,
                  self.live?.isFinal == false else { return }
            self.live?.translation = result.text
            self.lastTranslatedMasked = normalized
        }
    }

    private func cancelPartialTranslation() {
        partialGeneration += 1
        partialTask?.cancel()
        partialTask = nil
        needsAnotherPartial = false
    }

    /// 有空格的语言去掉末尾一个词（末词最易被 ASR 改写）；CJK 不裁剪，仅靠节流。
    static func maskedSource(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(" ") else { return trimmed }
        var tokens = trimmed.split(separator: " ")
        guard tokens.count > 1 else { return trimmed }
        tokens.removeLast()
        return tokens.joined(separator: " ")
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？,.!?…"))
            .lowercased()
    }

    // MARK: - 翻译

    private func volatileTranslate(_ request: TranslationRequest) async throws -> TranslationResult {
        if let supporting = translationService as? VolatileTranslationSupporting {
            return try await supporting.translateVolatile(request)
        }
        return try await translationService.translate(request)
    }

    private func translateFinal(_ text: String, source: Language, target: Language) async throws -> TranslationResult {
        let key = TranslationMemoryCache.Key(
            engineID: "voice",
            sourceCode: source.code,
            targetCode: target.code,
            text: text
        )
        if let cached = finalCache.result(for: key) {
            return cached
        }
        let request = TranslationRequest(text: text, source: source, target: target)
        let result = try await translationService.translate(request)
        finalCache.store(result, for: key)
        return result
    }

    // MARK: - 停止与失败

    private func userStop() {
        userRequestedPause = true
        if let live, !live.original.isEmpty {
            requestEndpoint()
        } else {
            hardStop()
        }
    }

    private func restartConversation() {
        hardStop()
        startListening()
    }

    private func hardStop() {
        userRequestedPause = true
        loopGeneration += 1
        speakGeneration += 1
        conversationTask?.cancel()
        conversationTask = nil
        // 在途的权威翻译取消并标记失败（气泡内可重试）；朗读队列清空。
        turnTranslationTasks.values.forEach { $0.cancel() }
        turnTranslationTasks.removeAll()
        pendingAutoSpeech.removeAll()
        isAutoSpeaking = false
        queuedMode = nil
        cancelPartialTranslation()
        let service = self.service
        let previousCancel = pendingServiceCancel
        pendingServiceCancel = Task {
            await previousCancel?.value
            await service?.cancel()
        }
        synthesizer.stop()
        live = nil
        audioLevel = 0
        assetDownloadProgress = nil
        phase = .idle
    }

    private func fail(with error: Error) {
        cancelPartialTranslation()
        live = nil
        audioLevel = 0
        assetDownloadProgress = nil
        let message = Self.message(for: error)
        switch error {
        case SpeechTranscriptionError.microphoneDenied,
             SpeechTranscriptionError.speechAuthorizationDenied:
            phase = .failed(.permissionDenied(message: message))
        default:
            phase = .failed(.other(message: message))
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return SpeechTranscriptionError.recognitionFailed.errorDescription ?? String(localized: "语音识别出错，请重试")
    }

    private func inferredLanguageCode(for turn: ConversationTurn) -> String? {
        // 兼容无 translationLanguageCode 的演示数据：按讲话方推断译文语言。
        let target = turn.speaker == .source ? voiceTarget : voiceSource
        return target.speechLocaleIdentifier
    }
}

/// 部分文本的低延迟重译入口；未实现方回落到权威 translate。
protocol VolatileTranslationSupporting {
    func translateVolatile(_ request: TranslationRequest) async throws -> TranslationResult
}
