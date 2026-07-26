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

/// 一次性闸门：让首个请求挂起，直到被取消或显式放行。
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

final class TranslationSessionDraftTests: XCTestCase {
    private func makeSettings() -> AppSettings {
        let suiteName = "TranslationSessionDraftTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults)
    }

    @MainActor
    func testDraftChangesStayIsolatedUntilCommit() async {
        let service = MockTranslationService { _ in
            TranslationResult(
                text: "おはようございます",
                detectedLanguage: nil,
                alternatives: ["おはよう"]
            )
        }
        let session = TranslationSession(settings: makeSettings(), service: service)
        let committedSourceText = session.sourceText
        let committedTranslation = session.translatedText
        let committedSourceLanguage = session.sourceLanguage
        let committedTargetLanguage = session.targetLanguage

        var draft = session.makeTextDraft()
        draft.sourceText = "Good morning"
        draft.sourceLanguage = .english
        draft.targetLanguage = .japanese

        XCTAssertEqual(session.sourceText, committedSourceText)
        XCTAssertEqual(session.translatedText, committedTranslation)
        XCTAssertEqual(session.sourceLanguage, committedSourceLanguage)
        XCTAssertEqual(session.targetLanguage, committedTargetLanguage)

        session.commitAndTranslate(draft)

        XCTAssertEqual(session.sourceText, "Good morning")
        XCTAssertEqual(session.sourceLanguage, .english)
        XCTAssertEqual(session.targetLanguage, .japanese)
        XCTAssertEqual(session.phase, .loading)

        await session.translationTask?.value

        XCTAssertEqual(session.translatedText, "おはようございます")
        XCTAssertEqual(session.translationCandidates, ["おはようございます", "おはよう"])
        XCTAssertEqual(session.phase, .idle)
    }

    @MainActor
    func testCommittingEmptyDraftClearsCurrentTranslationWithoutServiceCall() async {
        let counter = CallCounter()
        let service = MockTranslationService { _ in
            await counter.increment()
            return TranslationResult(text: "unexpected", detectedLanguage: nil, alternatives: [])
        }
        let session = TranslationSession(settings: makeSettings(), service: service)
        var draft = session.makeTextDraft()
        draft.sourceText = "\n  "

        session.commitAndTranslate(draft)
        await session.translationTask?.value

        XCTAssertEqual(session.sourceText, "\n  ")
        XCTAssertTrue(session.translatedText.isEmpty)
        XCTAssertTrue(session.translationCandidates.isEmpty)
        XCTAssertEqual(session.phase, .idle)
        let callCount = await counter.count
        XCTAssertEqual(callCount, 0)
    }

    @MainActor
    func testTranslationFailureShowsChineseErrorAndRetryRecovers() async {
        let failSwitch = FailSwitch()
        let service = MockTranslationService { _ in
            if await failSwitch.current() {
                throw TranslationError.rateLimited
            }
            return TranslationResult(text: "Hello", detectedLanguage: nil, alternatives: [])
        }
        let session = TranslationSession(settings: makeSettings(), service: service)
        var draft = session.makeTextDraft()
        draft.sourceText = "你好"

        session.commitAndTranslate(draft)
        await session.translationTask?.value

        XCTAssertEqual(session.phase, .failed(.rateLimited))
        XCTAssertTrue(session.translatedText.isEmpty)
        XCTAssertEqual(TranslationError.rateLimited.errorDescription, "请求过于频繁，请稍后再试")

        await failSwitch.disable()
        session.refreshTranslation()
        await session.translationTask?.value

        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.translatedText, "Hello")
    }

    @MainActor
    func testNewTranslationCancelsPreviousRequest() async {
        let gate = Gate()
        let service = MockTranslationService { request in
            if request.text == "first" {
                await gate.wait()
                return TranslationResult(text: "FIRST", detectedLanguage: nil, alternatives: [])
            }
            return TranslationResult(text: "SECOND", detectedLanguage: nil, alternatives: [])
        }
        let session = TranslationSession(settings: makeSettings(), service: service)

        var draft = session.makeTextDraft()
        draft.sourceText = "first"
        session.commitAndTranslate(draft)
        let firstTask = session.translationTask

        draft.sourceText = "second"
        session.commitAndTranslate(draft)
        gate.open()

        await firstTask?.value
        await session.translationTask?.value

        XCTAssertEqual(session.translatedText, "SECOND")
        XCTAssertEqual(session.phase, .idle)
    }

    @MainActor
    func testAutoDetectStoresDetectedLanguageAndSwapUsesIt() async {
        let service = MockTranslationService { _ in
            TranslationResult(text: "你好", detectedLanguage: .english, alternatives: [])
        }
        let session = TranslationSession(settings: makeSettings(), service: service)
        var draft = session.makeTextDraft()
        draft.sourceText = "Hello"
        draft.sourceLanguage = .auto
        draft.targetLanguage = .chinese

        session.commitAndTranslate(draft)
        await session.translationTask?.value

        XCTAssertEqual(session.detectedLanguage, .english)
        XCTAssertTrue(session.isSwapEnabled)
        XCTAssertEqual(session.sourceDisplayName, "English · 已检测")

        session.swapLanguages()

        XCTAssertEqual(session.sourceLanguage, .chinese)
        XCTAssertEqual(session.targetLanguage, .english)
        XCTAssertEqual(session.sourceText, "你好")
        await session.translationTask?.value
    }

    @MainActor
    func testSwapIsNoOpWhileAutoDetectHasNoResult() async {
        let service = MockTranslationService { _ in
            TranslationResult(text: "你好", detectedLanguage: nil, alternatives: [])
        }
        let session = TranslationSession(settings: makeSettings(), service: service)
        var draft = session.makeTextDraft()
        draft.sourceText = "Hello"
        draft.sourceLanguage = .auto
        draft.targetLanguage = .chinese

        session.commitAndTranslate(draft)
        await session.translationTask?.value

        XCTAssertNil(session.detectedLanguage)
        XCTAssertFalse(session.isSwapEnabled)

        session.swapLanguages()

        XCTAssertEqual(session.sourceLanguage, .auto)
        XCTAssertEqual(session.targetLanguage, .chinese)
        XCTAssertEqual(session.sourceText, "Hello")
    }

    @MainActor
    func testRepeatedTranslationHitsCacheWithoutSecondServiceCall() async {
        let counter = CallCounter()
        let service = MockTranslationService { _ in
            await counter.increment()
            return TranslationResult(text: "Hello", detectedLanguage: nil, alternatives: ["Hi"])
        }
        let session = TranslationSession(settings: makeSettings(), service: service)
        var draft = session.makeTextDraft()
        draft.sourceText = "你好"

        session.commitAndTranslate(draft)
        await session.translationTask?.value
        XCTAssertEqual(session.translatedText, "Hello")

        session.clearCurrent()
        XCTAssertTrue(session.translatedText.isEmpty)

        // 相同引擎、语言对与原文：直接命中缓存，同步出结果，不再调用服务。
        session.commitAndTranslate(draft)
        XCTAssertNil(session.translationTask)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.translatedText, "Hello")
        XCTAssertEqual(session.translationCandidates, ["Hello", "Hi"])
        let callCount = await counter.count
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testSessionRestoresStoredLanguagePairWithBlankCanvas() {
        let settings = makeSettings()
        settings.lastSourceLanguageCode = "ja"
        settings.lastTargetLanguageCode = "ko"

        let session = TranslationSession(settings: settings, service: nil)

        XCTAssertEqual(session.sourceLanguage.code, "ja")
        XCTAssertEqual(session.targetLanguage.code, "ko")
        XCTAssertTrue(session.sourceText.isEmpty)
        XCTAssertTrue(session.translatedText.isEmpty)
        XCTAssertTrue(session.translationCandidates.isEmpty)
    }
}
