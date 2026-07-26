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

/// iOS 26+ 的现代识别：SpeechAnalyzer + SpeechTranscriber（纯本地、无时长上限）。
///
/// **持久会话模型（实时性的关键）**：analyzer、transcriber 模块、音频引擎与
/// 输入流在整个聆听会话中只建一次——prepare 阶段就用 `.processLifetime` 模型
/// 驻留 + `prepareToAnalyze` 预热；句间用 `finalize(through: nil)` 切分而不是
/// 销毁重建（重建 = 每句话都付一次秒级模型加载），TTS 播放与句间间隙靠挂起
/// 音频源丢弃 buffer 维持半双工。
///
/// 多语言自动检测 = 一个 analyzer 挂多个语言的 transcriber 模块并行出结果，
/// 按打分选胜者（开口 0.7s 内免滞回自由改选）；多模块启动失败降级为首语言单轨。
/// 该路径只需麦克风权限——Apple 文档明确 analyzer 模块不向服务器发送音频。
/// 注意：喂入音频必须转换到 bestAvailableAudioFormat，格式不匹配是静默无结果；
/// 不读 AnalyzerInput.buffer（iOS 27 起废弃），只构造传入。
@available(iOS 26.0, *)
@MainActor
final class SpeechAnalyzerTranscriptionService: VoiceTranscriptionService {
    private final class Track {
        let language: Language
        let transcriber: SpeechTranscriber
        /// 会话级累计的 finalized 分段；utterance 边界用消费基线切分——
        /// 识别连续不断流，句界期间说的话落在基线之后，归属下一句，零丢词。
        var finalizedParts: [String] = []
        var consumedParts = 0
        var volatileTail = ""
        var latestConfidence: Double = 0

        init(language: Language, transcriber: SpeechTranscriber) {
            self.language = language
            self.transcriber = transcriber
        }

        /// 本句进行中的全文（基线之后的 finalized + volatile 尾巴）。
        var combinedText: String {
            (finalizedParts[consumedParts...].joined() + volatileTail)
                .trimmingCharacters(in: .whitespaces)
        }

        /// 本句已定稿的文本（基线之后的 finalized）。
        var finalText: String {
            finalizedParts[consumedParts...].joined().trimmingCharacters(in: .whitespaces)
        }

        /// 推进基线到当前：本句消费完毕，之后的结果属于下一句。
        func consumeUtterance() {
            consumedParts = finalizedParts.count
            volatileTail = ""
        }
    }

    // 会话级状态（跨 utterance 持久）
    private let audioSource = MicrophoneAudioSource()
    private var analyzer: SpeechAnalyzer?
    private var tracks: [Track] = []
    private var sessionLanguageCodes: [String] = []
    private var analyzerFormat: AVAudioFormat?
    private var audioAttached = false
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var feedTask: Task<Void, Never>?
    private var resultTasks: [Task<Void, Never>] = []
    /// 会话代际号：过期的异步收尾不得清掉重建后的会话状态。
    private var sessionGeneration = 0

    // utterance 级状态
    private var continuation: AsyncThrowingStream<SpeechTranscriptionEvent, Error>.Continuation?
    private var candidates: [Language] = []
    private var winnerIndex: Int?
    private var lastEmittedVolatile = ""
    private var firstVolatileAt: Date?
    private var finishFallbackTask: Task<Void, Never>?

    /// 运行时可用性：模拟器（无 ANE）与 A13 及更老机型上 supportedLocales 为空。
    static func isUsable() async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        return await !SpeechTranscriber.supportedLocales.isEmpty
    }

    // MARK: - 准备（含模型预热）

    func prepare(
        for languages: [Language],
        downloadProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw SpeechTranscriptionError.microphoneDenied
        }

        // 逐语言安装资产：单个候选语言装不上（离线/存储不足）不拖垮整段会话——
        // 自动模式与多轨降级天然容忍缺轨，只有全军覆没才报错。
        var anySupported = false
        var anyInstalled = false
        for language in languages {
            let locale = Locale(identifier: language.speechLocaleIdentifier)
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                continue
            }
            anySupported = true
            let transcriber = Self.makeTranscriber(locale: supported)
            do {
                try await installAssetsIfNeeded(for: transcriber, downloadProgress: downloadProgress)
                anyInstalled = true
            } catch {
                // 可能是预留上限：释放非本次会话语言的预留后重试一次。
                let sessionLocales = Set(languages.map {
                    Locale(identifier: $0.speechLocaleIdentifier).identifier(.bcp47)
                })
                for reserved in await AssetInventory.reservedLocales
                where !sessionLocales.contains(reserved.identifier(.bcp47)) {
                    await AssetInventory.release(reservedLocale: reserved)
                }
                if (try? await installAssetsIfNeeded(for: transcriber, downloadProgress: downloadProgress)) != nil {
                    anyInstalled = true
                }
            }
        }
        guard anySupported else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }
        guard anyInstalled else {
            throw SpeechTranscriptionError.assetUnavailable
        }

        // 在用户开口之前就建好识别链并预热模型：首句 volatile 才能亚秒出现。
        try await ensureSessionCore(languages: languages)
        downloadProgress(1)
    }

    // MARK: - 会话构建

    /// analyzer + 模块 + 格式 + 模型预热（不含音频接线，麦克风指示灯不提前亮）。
    private func ensureSessionCore(languages: [Language]) async throws {
        let codes = languages.map(\.code)
        if analyzer != nil, sessionLanguageCodes == codes { return }
        await teardownSession()

        var resolvedTracks: [Track] = []
        for language in languages {
            let locale = Locale(identifier: language.speechLocaleIdentifier)
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { continue }
            resolvedTracks.append(Track(language: language, transcriber: Self.makeTranscriber(locale: supported)))
        }
        guard !resolvedTracks.isEmpty else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }

        do {
            try await buildAnalyzer(tracks: resolvedTracks, codes: codes)
        } catch where resolvedTracks.count > 1 {
            // 多模块可能受设备资源限制：降级为首语言单轨（手动切换仍可用）。
            try await buildAnalyzer(tracks: [resolvedTracks[0]], codes: codes)
        }
    }

    private func buildAnalyzer(tracks: [Track], codes: [String]) async throws {
        // 模型进程级驻留：会话/语言切换重建 analyzer 时不再付模型加载成本。
        let analyzer = SpeechAnalyzer(
            modules: tracks.map(\.transcriber),
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: tracks.map(\.transcriber)) else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }
        try? await analyzer.prepareToAnalyze(in: format)
        self.analyzer = analyzer
        self.tracks = tracks
        self.analyzerFormat = format
        self.sessionLanguageCodes = codes
        self.audioAttached = false
        sessionGeneration += 1
        startResultConsumers(generation: sessionGeneration)
    }

    /// 音频接线：引擎、转换器、输入流与 analyzer.start，一个会话只做一次。
    private func attachAudioIfNeeded() async throws {
        guard !audioAttached, let analyzer, let analyzerFormat else { return }
        let chunks = try audioSource.start()
        guard let inputFormat = audioSource.inputFormat,
              let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
            audioSource.stop()
            throw SpeechTranscriptionError.audioSessionFailure
        }

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputBuilder = inputBuilder
        let format = analyzerFormat

        feedTask = Task.detached { [weak self] in
            for await chunk in chunks {
                if let converted = Self.convert(chunk.buffer, using: converter, to: format) {
                    inputBuilder.yield(AnalyzerInput(buffer: converted))
                }
                let level = chunk.level
                Task { @MainActor [weak self] in
                    self?.continuation?.yield(.audioLevel(level))
                }
            }
            inputBuilder.finish()
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            await teardownSession()
            throw SpeechTranscriptionError.recognitionFailed
        }
        audioAttached = true
    }

    /// 会话级结果消费：每条轨道一个任务，活到会话结束；
    /// 结果只在有活跃 utterance（continuation 非空）时上屏。
    private func startResultConsumers(generation: Int) {
        resultTasks = tracks.enumerated().map { index, track in
            let transcriber = track.transcriber
            return Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, self.sessionGeneration == generation else { return }
                        self.applyResult(result, toTrack: index)
                    }
                } catch {
                    // 单轨失败不打断整段；其余轨道继续。
                }
            }
        }
    }

    // MARK: - Utterance 生命周期

    func startUtterance(
        languages: [Language]
    ) async throws -> AsyncThrowingStream<SpeechTranscriptionEvent, Error> {
        candidates = languages
        try await ensureSessionCore(languages: languages)
        try await attachAudioIfNeeded()

        winnerIndex = nil
        lastEmittedVolatile = ""
        firstVolatileAt = nil

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechTranscriptionEvent.self)
        self.continuation = continuation
        audioSource.setSuspended(false)
        // 句界期间（上一句 resolve 到本次 start 之间）已积累的语音立即上屏。
        emitBestVolatile()
        return stream
    }

    func finishUtterance() async {
        guard let analyzer, continuation != nil else { return }
        // 音频不挂起：finalize 只是切分点，识别对下一句持续进行（live translate 的关键）。
        finishFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            // finalize 卡住的兜底：直接以现有文本定稿，不杀会话。
            self.resolveUtterance()
        }
        try? await analyzer.finalize(through: nil)
        finishFallbackTask?.cancel()
        finishFallbackTask = nil
        resolveUtterance()
    }

    func setInputSuspended(_ suspended: Bool) {
        audioSource.setSuspended(suspended)
    }

    func cancel() async {
        finishFallbackTask?.cancel()
        finishFallbackTask = nil
        continuation?.finish()
        continuation = nil
        await teardownSession()
    }

    // MARK: - 结果聚合

    private func applyResult(_ result: SpeechTranscriber.Result, toTrack index: Int) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        let text = String(result.text.characters)
        if let confidence = Self.averageConfidence(of: result.text) {
            track.latestConfidence = confidence
        }
        if result.isFinal {
            track.finalizedParts.append(text)
            track.volatileTail = ""
        } else {
            track.volatileTail = text
        }
        // 句间（无活跃 utterance）到达的迟到结果只更新轨道状态，不上屏。
        guard continuation != nil else { return }
        emitBestVolatile()
    }

    private func emitBestVolatile() {
        let scores = tracks.map { track in
            TranscriptionLanguageScorer.score(
                text: track.combinedText,
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
        let text = winner.combinedText
        guard !text.isEmpty, text != lastEmittedVolatile else { return }
        lastEmittedVolatile = text
        continuation?.yield(.volatile(text, winner.language))
    }

    /// 本句定稿：按含尾巴的全文重新打分选胜者（不带滞回），发 final 并结束事件流；
    /// 随后推进全轨基线——识别链与音频保持运转，句界后的语音归属下一句。
    private func resolveUtterance() {
        guard let continuation else { return }
        finishFallbackTask?.cancel()
        finishFallbackTask = nil
        // 正常 finalize 后 volatileTail 已清空；兜底路径回落 combinedText 防丢句。
        func resolvedText(_ track: Track) -> String {
            track.finalText.isEmpty ? track.combinedText : track.finalText
        }
        let scores = tracks.map { track in
            TranscriptionLanguageScorer.score(
                text: resolvedText(track),
                language: track.language,
                candidates: candidates,
                confidence: track.latestConfidence
            )
        }
        let index = TranscriptionLanguageScorer.winnerIndex(current: nil, scores: scores)
        let winner = index.flatMap { tracks.indices.contains($0) ? tracks[$0] : nil }
        let text = winner.map(resolvedText) ?? ""
        for track in tracks {
            track.consumeUtterance()
        }
        continuation.yield(.final(text, winner?.language ?? candidates.first ?? .english))
        continuation.finish()
        self.continuation = nil
    }

    // MARK: - 会话收尾

    /// self 状态在挂起点（cancelAndFinishNow）之前同步清空并捕获成局部量，
    /// 挂起恢复后不再触碰 self——期间重建的新会话不受过期收尾影响。
    private func teardownSession() async {
        sessionGeneration += 1
        audioSource.stop()
        inputBuilder?.finish()
        inputBuilder = nil
        feedTask?.cancel()
        feedTask = nil
        resultTasks.forEach { $0.cancel() }
        resultTasks = []
        tracks = []
        sessionLanguageCodes = []
        analyzerFormat = nil
        audioAttached = false
        let analyzer = self.analyzer
        self.analyzer = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // fastResults：更快出首个 volatile；置信度参与多轨胜者打分。
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.transcriptionConfidence]
        )
    }

    private func installAssetsIfNeeded(
        for transcriber: SpeechTranscriber,
        downloadProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        let progress = installation.progress
        let progressTask = Task { @MainActor in
            while !Task.isCancelled, !progress.isFinished {
                downloadProgress(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { progressTask.cancel() }
        try await installation.downloadAndInstall()
    }

    /// 从结果 AttributedString 的置信度属性取均值（需 attributeOptions 开启）。
    private static func averageConfidence(of text: AttributedString) -> Double? {
        var total = 0.0
        var count = 0.0
        for run in text.runs {
            if let value = run.transcriptionConfidence {
                total += Double(value)
                count += 1
            }
        }
        return count > 0 ? total / count : nil
    }

    /// 流式逐 buffer 转换：每次 convert 只喂一个输入 buffer。在采集任务线程调用。
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}
