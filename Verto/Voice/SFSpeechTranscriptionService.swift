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
import Speech

/// iOS 17–25（及模拟器）的回退识别：SFSpeechRecognizer 流水线。
/// 多语言自动检测 = 每个语言一条识别轨并行喂同一路音频，按打分选胜者；
/// 单轨失败不打断整段（模拟器上 en 本地识别器无法初始化、zh 服务器路径可用，
/// 正是靠多轨降级才能在模拟器上真实可用）。
/// 该路径需要麦克风与语音识别双权限；服务器识别有约 1 分钟上限，
/// 由 controller 的 55s 硬上限先行兜住。
@MainActor
final class SFSpeechTranscriptionService: VoiceTranscriptionService {
    private final class Track {
        let language: Language
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        var latestText = ""
        var latestConfidence: Double = 0
        var finalText: String?
        var failed = false

        init(language: Language, request: SFSpeechAudioBufferRecognitionRequest) {
            self.language = language
            self.request = request
        }

        var isResolved: Bool { failed || finalText != nil }
    }

    private let audioSource = MicrophoneAudioSource()
    private var tracks: [Track] = []
    private var candidates: [Language] = []
    private var winnerIndex: Int?
    private var feedTask: Task<Void, Never>?
    private var finishFallbackTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<SpeechTranscriptionEvent, Error>.Continuation?
    private var lastEmittedVolatile = ""
    private var finishRequested = false
    private var startedAt = Date()
    private var firstVolatileAt: Date?
    /// 每段话的代际号：过期的守护进程迟到回调不得打死新一段。
    private var utteranceGeneration = 0

    func prepare(
        for languages: [Language],
        downloadProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SpeechTranscriptionError.microphoneDenied
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw SpeechTranscriptionError.speechAuthorizationDenied
        }
        let anyAvailable = languages.contains { language in
            SFSpeechRecognizer(locale: Locale(identifier: language.speechLocaleIdentifier))?.isAvailable == true
        }
        guard anyAvailable else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }
        downloadProgress(1)
    }

    func startUtterance(
        languages: [Language]
    ) async throws -> AsyncThrowingStream<SpeechTranscriptionEvent, Error> {
        utteranceGeneration += 1
        let generation = utteranceGeneration
        candidates = languages

        var newTracks: [Track] = []
        for language in languages {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.speechLocaleIdentifier)),
                  recognizer.isAvailable else { continue }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            newTracks.append(Track(language: language, request: request))
        }
        guard !newTracks.isEmpty else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }
        tracks = newTracks
        winnerIndex = nil
        lastEmittedVolatile = ""
        finishRequested = false
        startedAt = Date()
        firstVolatileAt = nil

        let chunks = try audioSource.start()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechTranscriptionEvent.self)
        self.continuation = continuation

        let requests = newTracks.map(\.request)
        feedTask = Task.detached {
            for await chunk in chunks {
                for request in requests {
                    request.append(chunk.buffer)
                }
                continuation.yield(.audioLevel(chunk.level))
            }
            // 采集意外终止（路由格式变化等）时也让识别定稿，而不是干等。
            for request in requests {
                request.endAudio()
            }
        }

        for (index, track) in newTracks.enumerated() {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: track.language.speechLocaleIdentifier)) else {
                track.failed = true
                continue
            }
            track.task = recognizer.recognitionTask(with: track.request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    // 已取消段落的识别任务会在守护进程队列上迟到回调：代际号挡掉过期事件。
                    guard let self, self.utteranceGeneration == generation else { return }
                    self.handleRecognition(trackIndex: index, result: result, error: error)
                }
            }
        }
        return stream
    }

    func finishUtterance() async {
        guard continuation != nil, !finishRequested else { return }
        finishRequested = true
        audioSource.stop()
        for track in tracks {
            track.request.endAudio()
        }
        // endAudio 后 final 结果通常很快回来；3 秒兜底以最优 volatile 定稿。
        finishFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.resolveFinal()
        }
    }

    func cancel() async {
        finishFallbackTask?.cancel()
        finishFallbackTask = nil
        guard let continuation else { return }
        continuation.finish()
        cleanup()
    }

    func setInputSuspended(_ suspended: Bool) {
        audioSource.setSuspended(suspended)
    }

    // MARK: - 识别回调与胜者判定

    private func handleRecognition(trackIndex: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        guard continuation != nil, tracks.indices.contains(trackIndex) else { return }
        let track = tracks[trackIndex]

        if let result {
            let text = result.bestTranscription.formattedString
            let confidences = result.bestTranscription.segments.map { Double($0.confidence) }
            let confidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count)
            if result.isFinal {
                track.finalText = text
                track.latestText = text
                track.latestConfidence = confidence
                resolveFinalIfReady()
                return
            }
            if text != track.latestText {
                track.latestText = text
                track.latestConfidence = confidence
                emitBestVolatile()
            }
        }

        guard error != nil, !track.failed, track.finalText == nil else { return }
        if finishRequested {
            // endAudio 后的终止常以 error 形式到达：以该轨最后的 volatile 定稿。
            track.finalText = track.latestText
            resolveFinalIfReady()
        } else {
            track.failed = true
            // 全轨失败的错误文案优先；否则混合态（有轨已 final、余轨失败）
            // 也要立即定稿，不能留着麦克风僵死聆听等端点计时兜底。
            resolveIfAllTracksFailed()
            resolveFinalIfReady()
        }
    }

    private func emitBestVolatile() {
        let scores = tracks.map { track in
            track.failed ? 0 : TranscriptionLanguageScorer.score(
                text: track.latestText,
                language: track.language,
                candidates: candidates,
                confidence: track.latestConfidence
            )
        }
        if firstVolatileAt == nil, scores.contains(where: { $0 > 0 }) {
            firstVolatileAt = Date()
        }
        // 开口初期免滞回自由改选，避免先出结果的轨道抢跑锁定错误语言。
        let hysteresis: Double = firstVolatileAt.map {
            Date().timeIntervalSince($0) < VoiceTuning.winnerFreeReelectionWindow ? 0 : 0.15
        } ?? 0
        winnerIndex = TranscriptionLanguageScorer.winnerIndex(
            current: winnerIndex,
            scores: scores,
            hysteresis: hysteresis
        )
        guard let winnerIndex, tracks.indices.contains(winnerIndex) else { return }
        let winner = tracks[winnerIndex]
        guard !winner.latestText.isEmpty, winner.latestText != lastEmittedVolatile else { return }
        lastEmittedVolatile = winner.latestText
        continuation?.yield(.volatile(winner.latestText, winner.language))
    }

    /// 全轨 resolve（final 或 failed）后按 final 文本重新打分定胜者。
    private func resolveFinalIfReady() {
        guard tracks.allSatisfy(\.isResolved) else { return }
        resolveFinal()
    }

    private func resolveIfAllTracksFailed() {
        guard tracks.allSatisfy(\.failed) else { return }
        // 全部轨道失败：无文本的启动即失败按环境给出可行动的文案。
        if !finishRequested, tracks.allSatisfy({ $0.latestText.isEmpty }),
           Date().timeIntervalSince(startedAt) < 2.5 {
#if targetEnvironment(simulator)
            failStream(.unsupportedInSimulator)
#else
            failStream(.recognitionFailed)
#endif
        } else if tracks.allSatisfy({ $0.latestText.isEmpty }) {
            // 无语音会话被系统终止：按空 final 丢弃处理。
            finishStream(text: "", language: candidates.first ?? .english)
        } else {
            failStream(.recognitionFailed)
        }
    }

    private func resolveFinal() {
        guard continuation != nil else { return }
        let scores = tracks.map { track -> Double in
            let text = track.finalText ?? track.latestText
            guard !track.failed || !text.isEmpty else { return 0 }
            return TranscriptionLanguageScorer.score(
                text: text,
                language: track.language,
                candidates: candidates,
                confidence: track.latestConfidence
            )
        }
        // final 打分带置信度、比 volatile 可靠：不带滞回从零重选。
        let index = TranscriptionLanguageScorer.winnerIndex(current: nil, scores: scores)
        guard let index, tracks.indices.contains(index) else {
            finishStream(text: "", language: candidates.first ?? .english)
            return
        }
        let winner = tracks[index]
        finishStream(text: winner.finalText ?? winner.latestText, language: winner.language)
    }

    // MARK: - 流收尾

    private func finishStream(text: String, language: Language) {
        guard let continuation else { return }
        continuation.yield(.final(text, language))
        continuation.finish()
        cleanup()
    }

    private func failStream(_ error: SpeechTranscriptionError) {
        guard let continuation else { return }
        continuation.finish(throwing: error)
        cleanup()
    }

    private func cleanup() {
        continuation = nil
        finishFallbackTask?.cancel()
        finishFallbackTask = nil
        for track in tracks {
            track.task?.cancel()
            track.task = nil
        }
        tracks = []
        feedTask?.cancel()
        feedTask = nil
        audioSource.stop()
        finishRequested = false
        lastEmittedVolatile = ""
        winnerIndex = nil
    }
}
