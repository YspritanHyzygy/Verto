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

@MainActor
private final class MockAppleTranslating: AppleTranslating {
    var behavior: (String) throws -> String = { _ in
        throw AppleTranslationUnavailableError(reason: "测试默认不可用")
    }
    private(set) var callCount = 0

    func translate(
        _ text: String,
        source: Language,
        target: Language,
        volatilePreferred: Bool
    ) async throws -> String {
        callCount += 1
        return try behavior(text)
    }
}

private final class RecordingFallback: TranslationService, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [TranslationRequest] = []

    var requests: [TranslationRequest] {
        lock.withLock { _requests }
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        // withLock, not lock()/unlock(): the latter is unavailable from async
        // contexts under Swift 6 (holding a lock across a suspension point).
        lock.withLock { _requests.append(request) }
        return TranslationResult(text: "回退:\(request.text)", detectedLanguage: nil, alternatives: [])
    }
}

@MainActor
final class VoiceTranslationRouterTests: XCTestCase {
    private func request(_ text: String) -> TranslationRequest {
        TranslationRequest(text: text, source: .english, target: .chinese)
    }

    func testAppleSuccessSkipsFallback() async throws {
        let apple = MockAppleTranslating()
        apple.behavior = { "苹果:\($0)" }
        let fallback = RecordingFallback()
        var decisions: [String] = []
        let router = VoiceTranslationRouter(apple: apple, fallback: fallback) { decisions.append($0) }

        let result = try await router.translate(request("hello"))

        XCTAssertEqual(result.text, "苹果:hello")
        XCTAssertTrue(fallback.requests.isEmpty)
        XCTAssertEqual(decisions, ["apple"])
    }

    func testAppleUnavailableFallsBackToGoogle() async throws {
        let apple = MockAppleTranslating()
        let fallback = RecordingFallback()
        var decisions: [String] = []
        let router = VoiceTranslationRouter(apple: apple, fallback: fallback) { decisions.append($0) }

        let result = try await router.translate(request("hello"))

        XCTAssertEqual(result.text, "回退:hello")
        XCTAssertEqual(fallback.requests.count, 1)
        XCTAssertEqual(decisions.first?.hasPrefix("google:"), true)
    }

    func testPairFailureMemoSkipsAppleOnSubsequentCalls() async throws {
        let apple = MockAppleTranslating()
        let fallback = RecordingFallback()
        let router = VoiceTranslationRouter(apple: apple, fallback: fallback)

        _ = try await router.translate(request("one"))
        _ = try await router.translateVolatile(request("two"))
        _ = try await router.translate(request("three"))

        XCTAssertEqual(apple.callCount, 1, "同一语言对失败后本会话不再尝试苹果路径")
        XCTAssertEqual(fallback.requests.count, 3)
    }

    func testResetPairMemosRetriesApple() async throws {
        let apple = MockAppleTranslating()
        let fallback = RecordingFallback()
        let router = VoiceTranslationRouter(apple: apple, fallback: fallback)

        _ = try await router.translate(request("one"))
        XCTAssertEqual(apple.callCount, 1)

        apple.behavior = { "苹果:\($0)" }
        router.resetPairMemos()
        let result = try await router.translate(request("two"))

        XCTAssertEqual(apple.callCount, 2)
        XCTAssertEqual(result.text, "苹果:two")
    }

    func testNilAppleGoesStraightToFallback() async throws {
        let fallback = RecordingFallback()
        var decisions: [String] = []
        let router = VoiceTranslationRouter(apple: nil, fallback: fallback) { decisions.append($0) }

        let result = try await router.translate(request("hello"))

        XCTAssertEqual(result.text, "回退:hello")
        XCTAssertEqual(decisions, ["google:no-apple"])
    }
}
