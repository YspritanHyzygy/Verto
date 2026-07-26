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

import XCTest
@testable import Verto

private struct MockTranslationService: TranslationService {
    let handler: @Sendable (TranslationRequest) async throws -> TranslationResult

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        try await handler(request)
    }
}

private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private actor FailSwitch {
    private var shouldFail = true

    func disable() {
        shouldFail = false
    }

    func current() -> Bool {
        shouldFail
    }
}

/// 一次性闸门：让请求挂起，直到显式放行。
private final class Gate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var continuation: AsyncStream<Void>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func wait() async {
        for await _ in stream {
            break
        }
    }

    func open() {
        continuation.finish()
    }
}

/// 手动驱动的识别服务：测试直接向事件流注入 volatile/final/level。
@MainActor
private final class ScriptedTranscriptionService: VoiceTranscriptionService {
    private(set) var prepareCalls: [[String]] = []
    private(set) var startCalls: [[String]] = []
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    var prepareError: SpeechTranscriptionError?
    var onFinish: (@MainActor () -> Void)?

    private var continuation: AsyncThrowingStream<SpeechTranscriptionEvent, Error>.Continuation?

    func prepare(
        for languages: [Language],
        downloadProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        prepareCalls.append(languages.map(\.code))
        if let prepareError {
            throw prepareError
        }
        downloadProgress(1)
    }

    func startUtterance(
        languages: [Language]
    ) async throws -> AsyncThrowingStream<SpeechTranscriptionEvent, Error> {
        startCalls.append(languages.map(\.code))
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechTranscriptionEvent.self)
        self.continuation = continuation
        return stream
    }

    func finishUtterance() async {
        finishCallCount += 1
        onFinish?()
    }

    func cancel() async {
        cancelCallCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emitVolatile(_ text: String, language: Language = .english) {
        continuation?.yield(.volatile(text, language))
    }

    func emitLevel(_ level: Float) {
        continuation?.yield(.audioLevel(level))
    }

    func emitFinal(_ text: String, language: Language = .english) {
        continuation?.yield(.final(text, language))
        continuation?.finish()
        continuation = nil
    }

    func failStream(_ error: SpeechTranscriptionError) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

@MainActor
private final class MockSynthesizer: SpeechSynthesizing {
    private(set) var spoken: [(text: String, code: String)] = []

    func speak(_ text: String, languageCode: String) async {
        spoken.append((text, languageCode))
    }

    func stop() {}
}

@MainActor
final class VoiceConversationControllerTests: XCTestCase {
    private func makeSettings() -> AppSettings {
        let suiteName = "VoiceConversationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults)
    }

    private func fastTiming() -> VoiceConversationController.Timing {
        var timing = VoiceConversationController.Timing()
        timing.partialThrottle = .milliseconds(10)
        timing.endpointVolatileStability = 10
        timing.endpointSilenceDuration = 10
        timing.maxUtteranceDuration = 30
        timing.noSpeechAutoPause = 30
        timing.endpointTick = 0.02
        return timing
    }

    private func makeController(
        service: ScriptedTranscriptionService,
        translation: any TranslationService,
        settings: AppSettings? = nil,
        synthesizer: MockSynthesizer? = nil,
        headphones: Bool = false,
        timing: VoiceConversationController.Timing? = nil
    ) -> VoiceConversationController {
        VoiceConversationController(
            settings: settings ?? makeSettings(),
            transcriptionFactory: { service },
            translationService: translation,
            synthesizer: synthesizer ?? MockSynthesizer(),
            headphonesConnected: { headphones },
            timing: timing ?? fastTiming()
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("waitUntil 超时")
    }

    private func echoTranslation() -> MockTranslationService {
        MockTranslationService { request in
            TranslationResult(text: "译:\(request.text)", detectedLanguage: nil, alternatives: [])
        }
    }

    // MARK: - 实时转写

    func testVolatileUpdatesLiveBubbleInPlace() async {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())

        controller.startListening()
        await waitUntil { controller.phase == .listening }

        service.emitVolatile("你")
        await waitUntil { controller.live?.original == "你" }

        service.emitVolatile("你好")
        await waitUntil { controller.live?.original == "你好" }
        XCTAssertEqual(controller.live?.isFinal, false)
    }

    func testPartialTranslationThrottleLimitsCalls() async {
        let counter = CallCounter()
        let translation = MockTranslationService { request in
            await counter.increment()
            return TranslationResult(text: "译:\(request.text)", detectedLanguage: nil, alternatives: [])
        }
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: translation)

        controller.startListening()
        await waitUntil { controller.phase == .listening }

        for index in 1...10 {
            service.emitVolatile((0...index).map { "词\($0)" }.joined(separator: " "))
        }
        await waitUntil { controller.live?.translation.isEmpty == false }
        try? await Task.sleep(for: .milliseconds(120))

        let calls = await counter.count
        XCTAssertLessThanOrEqual(calls, 3, "10 连发 volatile 应被节流为极少量翻译调用")
        XCTAssertGreaterThanOrEqual(calls, 1)
    }

    func testFinalArrivingWhilePartialInFlightWinsAuthoritatively() async {
        let gate = Gate()
        let translation = MockTranslationService { request in
            if request.text.hasPrefix("part") {
                await gate.wait()
                return TranslationResult(text: "PARTIAL", detectedLanguage: nil, alternatives: [])
            }
            return TranslationResult(text: "FINAL", detectedLanguage: nil, alternatives: [])
        }
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: translation)

        controller.startListening()
        await waitUntil { controller.phase == .listening }

        service.emitVolatile("part one two")
        try? await Task.sleep(for: .milliseconds(60))
        service.emitFinal("final sentence")
        await waitUntil { controller.turns.count == 1 }
        gate.open()

        // 权威翻译异步填充；被 gate 的旧方向 partial 结果不得覆盖。
        await waitUntil { controller.turns.first?.translation == "FINAL" }
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(controller.turns.first?.translation, "FINAL")
        XCTAssertNil(controller.live)
    }

    func testFinalCommitsTurnAndAutoRelistens() async {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())

        controller.startListening()
        await waitUntil { controller.phase == .listening }

        service.emitVolatile("Good morning")
        service.emitFinal("Good morning")

        await waitUntil { controller.turns.count == 1 }
        XCTAssertEqual(controller.turns.first?.original, "Good morning")
        // 权威翻译异步填充。
        await waitUntil { controller.turns.first?.translation == "译:Good morning" }
        XCTAssertEqual(controller.turns.first?.isTranslationPending, false)
        XCTAssertEqual(controller.turns.first?.speaker, .source)
        XCTAssertEqual(controller.turns.first?.translationLanguageCode, "zh-CN")
        XCTAssertNil(controller.live)

        // 半双工循环：提交后自动开始下一段。
        await waitUntil { service.startCalls.count == 2 }
        await waitUntil { controller.phase == .listening }
    }

    func testEndpointTimerRequestsFinishAfterStableSilence() async {
        var timing = fastTiming()
        timing.endpointVolatileStability = 0.1
        timing.endpointSilenceDuration = 0.05
        let service = ScriptedTranscriptionService()
        service.onFinish = { service.emitFinal("你好") }
        let controller = makeController(service: service, translation: echoTranslation(), timing: timing)

        controller.startListening()
        await waitUntil { controller.phase == .listening }

        service.emitVolatile("你好")
        await waitUntil { service.finishCallCount >= 1 }
        await waitUntil { controller.turns.count == 1 }
    }

    func testEmptyFinalIsDiscarded() async {
        let counter = CallCounter()
        let translation = MockTranslationService { _ in
            await counter.increment()
            return TranslationResult(text: "unused", detectedLanguage: nil, alternatives: [])
        }
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: translation)

        controller.startListening()
        await waitUntil { controller.phase == .listening }

        service.emitFinal("  \n ")
        await waitUntil { service.startCalls.count == 2 }

        XCTAssertTrue(controller.turns.isEmpty)
        XCTAssertNil(controller.live)
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }

    func testPlaybackModeMatrixControlsAutoSpeak() async {
        struct Case {
            let mode: VoicePlaybackMode
            let headphones: Bool
            let expectSpoken: Bool
        }
        let cases: [Case] = [
            Case(mode: .textOnly, headphones: false, expectSpoken: false),
            Case(mode: .textOnly, headphones: true, expectSpoken: false),
            Case(mode: .speakAfterTranslation, headphones: false, expectSpoken: true),
            Case(mode: .speakAfterTranslation, headphones: true, expectSpoken: true),
            Case(mode: .speakOnlyWithHeadphones, headphones: false, expectSpoken: false),
            Case(mode: .speakOnlyWithHeadphones, headphones: true, expectSpoken: true)
        ]

        for testCase in cases {
            let settings = makeSettings()
            settings.voicePlaybackMode = testCase.mode
            let synthesizer = MockSynthesizer()
            let service = ScriptedTranscriptionService()
            let controller = makeController(
                service: service,
                translation: echoTranslation(),
                settings: settings,
                synthesizer: synthesizer,
                headphones: testCase.headphones
            )

            controller.startListening()
            await waitUntil { controller.phase == .listening }
            service.emitFinal("hello there")
            await waitUntil { controller.turns.count == 1 }

            if testCase.expectSpoken {
                // 翻译异步完成后经朗读队列在间隙播放。
                await waitUntil { !synthesizer.spoken.isEmpty }
                XCTAssertEqual(synthesizer.spoken.first?.text, "译:hello there")
                XCTAssertEqual(synthesizer.spoken.first?.code, "zh-CN")
            } else {
                try? await Task.sleep(for: .milliseconds(80))
                XCTAssertTrue(
                    synthesizer.spoken.isEmpty,
                    "mode=\(testCase.mode) headphones=\(testCase.headphones)"
                )
            }
            controller.tearDown()
        }
    }

    // MARK: - 失败路径

    func testPermissionDenialSurfacesChineseMessage() async {
        let service = ScriptedTranscriptionService()
        service.prepareError = .microphoneDenied
        let controller = makeController(service: service, translation: echoTranslation())

        controller.startListening()
        await waitUntil { controller.isPermissionFailure }

        XCTAssertEqual(controller.statusText, "未获得麦克风权限，请在系统设置中开启")
        XCTAssertNil(controller.conversationTask)
    }

    func testRecognitionStreamErrorShowsRetriableFailure() async {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())

        controller.startListening()
        await waitUntil { controller.phase == .listening }
        service.emitVolatile("hal")
        service.failStream(.recognitionFailed)

        await waitUntil {
            if case .failed(.other) = controller.phase { return true }
            return false
        }
        XCTAssertEqual(controller.statusText, "语音识别出错，请重试")
        XCTAssertNil(controller.live)

        // 再次点按可恢复。
        controller.toggleListening()
        await waitUntil { controller.phase == .listening }
    }

    func testFinalTranslationFailureMarksTurnForRetryWhileListeningContinues() async {
        let failSwitch = FailSwitch()
        let translation = MockTranslationService { request in
            if await failSwitch.current() {
                throw TranslationError.network
            }
            return TranslationResult(text: "译:\(request.text)", detectedLanguage: nil, alternatives: [])
        }
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: translation)

        controller.startListening()
        await waitUntil { controller.phase == .listening }
        service.emitFinal("你好")

        // 定稿即上屏；翻译失败标在气泡上，识别不受影响、已自动续听。
        await waitUntil { controller.turns.first?.translationFailed == true }
        XCTAssertEqual(controller.turns.first?.original, "你好")
        XCTAssertNil(controller.live)
        await waitUntil { service.startCalls.count == 2 }
        XCTAssertEqual(controller.phase, .listening)

        await failSwitch.disable()
        controller.retryTranslation(for: controller.turns[0].id)

        await waitUntil { controller.turns.first?.translation == "译:你好" }
        XCTAssertEqual(controller.turns.first?.translationFailed, false)
        XCTAssertEqual(controller.turns.first?.isTranslationPending, false)
    }

    // MARK: - 控制

    func testTapDuringSilentListeningPausesWithoutTurn() async {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())

        controller.startListening()
        await waitUntil { controller.phase == .listening }

        controller.toggleListening()
        await waitUntil { controller.phase == .idle }
        await waitUntil { service.cancelCallCount >= 1 }

        XCTAssertTrue(controller.turns.isEmpty)
        XCTAssertEqual(controller.statusText, "已暂停 · 轻点继续")
    }

    func testTapDuringSpeechCommitsUtteranceThenPauses() async {
        let service = ScriptedTranscriptionService()
        service.onFinish = { service.emitFinal("Good morning") }
        let controller = makeController(service: service, translation: echoTranslation())

        controller.startListening()
        await waitUntil { controller.phase == .listening }
        service.emitVolatile("Good morning")
        await waitUntil { controller.live != nil }

        controller.toggleListening()
        await waitUntil { controller.turns.count == 1 }
        await waitUntil { controller.phase == .idle }

        // 用户主动暂停：不自动续听。
        XCTAssertEqual(service.startCalls.count, 1)
    }

    func testSetLanguagesCancelsInFlightUtterance() async {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())

        controller.startListening()
        await waitUntil { controller.phase == .listening }
        service.emitVolatile("hal")
        await waitUntil { controller.live != nil }

        controller.setLanguages(source: .japanese, target: .chinese)

        await waitUntil { controller.phase == .idle }
        await waitUntil { service.cancelCallCount >= 1 }
        XCTAssertNil(controller.live)
        XCTAssertEqual(controller.voiceSource, .japanese)
    }

    func testAutoTargetLanguageIsResolvedToConcreteLanguage() {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())

        controller.setLanguages(source: .english, target: .auto)

        XCTAssertEqual(controller.voiceSource, .english)
        XCTAssertEqual(controller.voiceTarget, .chinese)
    }

    func testSpeakerSwitchWhileIdleStartsListeningInThatLanguage() async {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())
        controller.setLanguages(source: .english, target: .chinese)

        controller.switchSpeaker(to: .target)

        await waitUntil { controller.phase == .listening }
        XCTAssertEqual(controller.activeSpeaker, .target)
        XCTAssertEqual(controller.listeningMode, .manual(.target))
        XCTAssertEqual(service.startCalls.last, ["zh-Hans"])
        XCTAssertEqual(controller.statusText, "正在聆听 · 中文")
    }

    func testTapActiveManualSpeakerReturnsToAutoDetection() async {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())
        controller.setLanguages(source: .english, target: .chinese)

        controller.switchSpeaker(to: .target)
        await waitUntil { controller.phase == .listening }
        XCTAssertEqual(service.startCalls.last, ["zh-Hans"])

        // 再点已锁定的一侧：回到自动检测（双语言轨）。
        controller.switchSpeaker(to: .target)
        await waitUntil { service.startCalls.last == ["en", "zh-Hans"] }
        XCTAssertEqual(controller.listeningMode, .auto)
        XCTAssertEqual(controller.statusText, "正在聆听 · English / 中文")
    }

    func testAutoDetectionRoutesBubbleAndDirectionByDetectedLanguage() async {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())
        controller.setLanguages(source: .english, target: .chinese)

        controller.startListening()
        await waitUntil { controller.phase == .listening }
        XCTAssertEqual(service.startCalls.last, ["en", "zh-Hans"], "自动模式并行监听语言对双语")

        // 检测到中文：气泡在 target 侧，翻译方向 zh→en。
        service.emitVolatile("你", language: .chinese)
        await waitUntil { controller.live?.speaker == .target }
        XCTAssertEqual(controller.activeSpeaker, .target)
        XCTAssertEqual(controller.live?.languageName, "中文")

        service.emitFinal("你好", language: .chinese)
        await waitUntil { controller.turns.count == 1 }
        XCTAssertEqual(controller.turns.first?.speaker, .target)
        XCTAssertEqual(controller.turns.first?.language, "中文")
        XCTAssertEqual(controller.turns.first?.translationLanguageCode, "en-US")
    }

    func testSpeakerSwitchDuringSpeechQueuesUntilCommit() async {
        let service = ScriptedTranscriptionService()
        service.onFinish = { service.emitFinal("Good morning") }
        let controller = makeController(service: service, translation: echoTranslation())
        controller.setLanguages(source: .english, target: .chinese)

        controller.startListening()
        await waitUntil { controller.phase == .listening }
        service.emitVolatile("Good morning")
        await waitUntil { controller.live != nil }

        controller.switchSpeaker(to: .target)

        await waitUntil { controller.turns.count == 1 }
        XCTAssertEqual(controller.turns.first?.speaker, .source, "切换前的话仍归原讲话方")
        await waitUntil { controller.activeSpeaker == .target }
        await waitUntil { service.startCalls.last == ["zh-Hans"] }
    }

    func testFinalTranslationResultIsCached() async {
        let counter = CallCounter()
        let translation = MockTranslationService { request in
            await counter.increment()
            return TranslationResult(text: "译:\(request.text)", detectedLanguage: nil, alternatives: [])
        }
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: translation)

        controller.startListening()
        await waitUntil { controller.phase == .listening }
        service.emitFinal("你好")
        await waitUntil { controller.turns.count == 1 }

        await waitUntil { service.startCalls.count == 2 }
        service.emitFinal("你好")
        await waitUntil { controller.turns.count == 2 }

        let calls = await counter.count
        XCTAssertEqual(calls, 1, "相同语言对与原文的 final 译文应命中缓存")
    }

    func testTearDownStopsEverythingButKeepsTurns() async {
        let service = ScriptedTranscriptionService()
        let controller = makeController(service: service, translation: echoTranslation())

        controller.startListening()
        await waitUntil { controller.phase == .listening }
        service.emitFinal("你好")
        await waitUntil { controller.turns.count == 1 }

        controller.tearDown()

        await waitUntil { controller.phase == .idle }
        XCTAssertEqual(controller.turns.count, 1)
        XCTAssertNil(controller.live)
        XCTAssertNil(controller.conversationTask)
    }
}
