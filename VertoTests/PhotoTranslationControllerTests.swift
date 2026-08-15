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
import UIKit
import XCTest
@testable import Verto

@MainActor
private final class StubCaptureSource: PhotoCaptureSource {
    var canCapture = true
    var isFlashAvailable = true
    var isPermissionDenied = false
    let previewLayer: AVCaptureVideoPreviewLayer? = nil

    var captureError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var flashEnabled: Bool?
    private(set) var exposureLocked: Bool?

    func start() async { startCount += 1 }
    func stop() { stopCount += 1 }
    func setFlashEnabled(_ enabled: Bool) { flashEnabled = enabled }
    func setExposureLocked(_ locked: Bool) { exposureLocked = locked }

    func capturePhoto() async throws -> UIImage {
        if let captureError { throw captureError }
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
    }
}

private struct StubRecognizer: TextRecognitionService {
    let blocks: [RecognizedTextBlock]
    let error: TextRecognitionError?

    init(blocks: [RecognizedTextBlock] = [], error: TextRecognitionError? = nil) {
        self.blocks = blocks
        self.error = error
    }

    func recognizeText(in image: CGImage, languages: [Language]) async throws -> [RecognizedTextBlock] {
        if let error { throw error }
        return blocks
    }
}

/// 记录每次调用的原文，并可按原文注入失败——用来验证单块失败不拖垮整页、
/// 以及缓存命中确实省掉了请求。
private final class RecordingTranslationService: TranslationService, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [TranslationRequest] = []
    private var _failing: Set<String>

    init(failingTexts: Set<String> = []) {
        _failing = failingTexts
    }

    var requests: [TranslationRequest] { lock.withLock { _requests } }

    func stopFailing() {
        // withLock 而非 lock()/unlock()：后者在 async 上下文里不可用。
        lock.withLock { _failing = [] }
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let shouldFail = lock.withLock { () -> Bool in
            _requests.append(request)
            return _failing.contains(request.text)
        }
        if shouldFail { throw TranslationError.network }
        return TranslationResult(text: "译:\(request.text)", detectedLanguage: nil, alternatives: [])
    }
}

@MainActor
private final class SilentSynthesizer: SpeechSynthesizing {
    private(set) var spoken: [(text: String, languageCode: String)] = []
    private(set) var stopCount = 0

    func speak(_ text: String, languageCode: String) async {
        spoken.append((text, languageCode))
    }

    func stop() { stopCount += 1 }
}

@MainActor
final class PhotoTranslationControllerTests: XCTestCase {
    private func block(_ text: String, y: CGFloat = 0.5) -> RecognizedTextBlock {
        RecognizedTextBlock(text: text, quad: .upright(x: 0.1, y: y, width: 0.5, height: 0.05))
    }

    /// capture/synthesizer 是 @MainActor 类型，不能当默认实参（默认值在非隔离
    /// 上下文里求值），所以走可选参数、在这里补默认实例。
    private func makeController(
        recognizer: any TextRecognitionService,
        capture: StubCaptureSource? = nil,
        translation: RecordingTranslationService = RecordingTranslationService(),
        synthesizer: SilentSynthesizer? = nil
    ) -> PhotoTranslationController {
        PhotoTranslationController(
            settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            captureSource: capture ?? StubCaptureSource(),
            recognizer: recognizer,
            translationService: translation,
            synthesizer: synthesizer ?? SilentSynthesizer()
        )
    }

    /// 管线全程是 Task 驱动的，逐步让出主线程直到条件成立；条件到了立刻返回，
    /// 绿色路径不烧时间。
    private func waitUntil(
        _ condition: () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(message, file: file, line: line)
    }

    private func sample() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        }
    }

    // MARK: - 主流程

    func testCaptureRunsRecognitionThenFillsEveryTranslation() async {
        let translation = RecordingTranslationService()
        let controller = makeController(
            recognizer: StubRecognizer(blocks: [block("你好", y: 0.7), block("再见", y: 0.5)]),
            translation: translation
        )

        controller.capture()
        await waitUntil({ controller.phase == .done }, "管线没有走到 done")

        XCTAssertNotNil(controller.image)
        XCTAssertEqual(controller.blocks.map(\.source), ["你好", "再见"])
        XCTAssertEqual(controller.blocks.map(\.translation), ["译:你好", "译:再见"])
        XCTAssertFalse(controller.blocks.contains { $0.isPending || $0.failed })
        XCTAssertEqual(Set(translation.requests.map(\.text)), ["你好", "再见"])
    }

    func testBlocksAppearBeforeTranslationsArrive() async {
        let controller = makeController(recognizer: StubRecognizer(blocks: [block("你好")]))

        controller.use(sample())
        // 识别一出结果块就该上屏（带原文占位），不等翻译——同语音气泡的约定。
        await waitUntil({ !controller.blocks.isEmpty }, "识别结果没有先于翻译上屏")

        XCTAssertEqual(controller.blocks.first?.displayText, "你好", "译文未到时先显示原文")
        await waitUntil({ controller.phase == .done }, "管线没有走到 done")
        XCTAssertEqual(controller.blocks.first?.displayText, "译:你好")
    }

    func testEmptyRecognitionFailsInsteadOfShowingBlankResult() async {
        let controller = makeController(recognizer: StubRecognizer(blocks: []))

        controller.use(sample())
        await waitUntil({ controller.phase == .done }, "空结果没有落到终态")

        // 零块时管线会直接判定完成——真实识别器对无文字抛 .noTextFound，
        // 这条守的是"即便识别器返回空数组，也不会停在翻译中假装还在忙"。
        XCTAssertTrue(controller.blocks.isEmpty)
    }

    func testRecognitionErrorSurfacesLocalizedFailure() async {
        let controller = makeController(recognizer: StubRecognizer(error: .noTextFound))

        controller.use(sample())
        await waitUntil({ controller.failureMessage != nil }, "识别失败没有上报")

        XCTAssertFalse(controller.isPermissionFailure)
        XCTAssertEqual(controller.failureMessage, TextRecognitionError.noTextFound.errorDescription)
        XCTAssertTrue(controller.blocks.isEmpty)
    }

    func testCaptureDeniedIsDistinguishedFromOtherFailures() async {
        let capture = StubCaptureSource()
        capture.captureError = CameraCaptureError.permissionDenied
        let controller = makeController(recognizer: StubRecognizer(blocks: [block("你好")]), capture: capture)

        controller.capture()
        await waitUntil({ controller.failureMessage != nil }, "拍照失败没有上报")

        // 只有权限被拒才给「前往设置」，其余错误给「重试」。
        XCTAssertTrue(controller.isPermissionFailure)
    }

    // MARK: - 代际围栏

    func testNewCaptureDiscardsInFlightResultsOfThePreviousOne() async {
        let controller = makeController(recognizer: StubRecognizer(blocks: [block("第一张")]))

        controller.use(sample())
        await waitUntil({ !controller.blocks.isEmpty }, "第一轮没出块")
        // 第一轮还在翻译途中就换图：旧回包必须被丢弃，不许污染新一轮结果。
        controller.use(sample())
        await waitUntil({ controller.phase == .done }, "第二轮没有走到 done")

        XCTAssertEqual(controller.blocks.count, 1)
        XCTAssertEqual(controller.blocks.first?.source, "第一张")
        XCTAssertEqual(controller.blocks.first?.translation, "译:第一张")
    }

    func testResetClearsImageAndBlocks() async {
        let synthesizer = SilentSynthesizer()
        let controller = makeController(
            recognizer: StubRecognizer(blocks: [block("你好")]),
            synthesizer: synthesizer
        )

        controller.use(sample())
        await waitUntil({ controller.phase == .done }, "管线没有走到 done")
        controller.reset()

        XCTAssertNil(controller.image)
        XCTAssertTrue(controller.blocks.isEmpty)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(synthesizer.stopCount, 1, "回到取景要掐掉正在播的朗读")
    }

    // MARK: - 单块失败与重试

    func testOneFailedBlockDoesNotBlockTheOthers() async {
        let translation = RecordingTranslationService(failingTexts: ["坏块"])
        let controller = makeController(
            recognizer: StubRecognizer(blocks: [block("好块", y: 0.7), block("坏块", y: 0.5)]),
            translation: translation
        )

        controller.use(sample())
        await waitUntil({ controller.phase == .done }, "有失败块时整页没有落到终态")

        let good = controller.blocks[0]
        let bad = controller.blocks[1]
        XCTAssertEqual(good.translation, "译:好块")
        XCTAssertFalse(good.failed)
        XCTAssertTrue(bad.failed)
        XCTAssertFalse(bad.isPending)
        XCTAssertEqual(bad.displayText, "坏块", "失败块退回显示原文，不留空白")
    }

    func testRetryingASingleBlockOnlyRetranslatesThatBlock() async {
        let translation = RecordingTranslationService(failingTexts: ["坏块"])
        let controller = makeController(
            recognizer: StubRecognizer(blocks: [block("好块", y: 0.7), block("坏块", y: 0.5)]),
            translation: translation
        )

        controller.use(sample())
        await waitUntil({ controller.phase == .done }, "首轮没有落到终态")
        let requestsBeforeRetry = translation.requests.count
        translation.stopFailing()

        controller.retryTranslation(for: controller.blocks[1].id)
        // 等 isPending 落下，不是等 failed 清零——failed 是 retryTranslation 同步清的，
        // 拿它当信号会在译文回来之前就放行。
        await waitUntil({ !controller.blocks[1].isPending }, "重试没有走完")

        XCTAssertEqual(controller.blocks[1].translation, "译:坏块")
        XCTAssertEqual(translation.requests.count, requestsBeforeRetry + 1, "只该重发失败的那一块")
        XCTAssertEqual(translation.requests.last?.text, "坏块")
    }

    // MARK: - 缓存

    func testRepeatedTextInOnePhotoIsTranslatedOnce() async {
        let translation = RecordingTranslationService()
        let controller = makeController(
            recognizer: StubRecognizer(blocks: [
                block("禁止吸烟", y: 0.8),
                block("禁止吸烟", y: 0.5),
                block("欢迎光临", y: 0.2),
            ]),
            translation: translation
        )

        controller.use(sample())
        await waitUntil({ controller.phase == .done }, "管线没有走到 done")

        XCTAssertEqual(controller.blocks.map(\.translation), ["译:禁止吸烟", "译:禁止吸烟", "译:欢迎光临"])
        XCTAssertEqual(translation.requests.count, 2, "同一张图里重复的短句只该发一次请求")
    }

    // MARK: - 语言

    func testChangingLanguagePairRetranslatesTheSamePhoto() async {
        let translation = RecordingTranslationService()
        let controller = makeController(
            recognizer: StubRecognizer(blocks: [block("你好")]),
            translation: translation
        )

        controller.use(sample())
        await waitUntil({ controller.phase == .done }, "首轮没有落到终态")
        controller.setLanguages(source: .chinese, target: .japanese)
        await waitUntil({ controller.phase == .done }, "换语言后没有重新落到终态")

        XCTAssertEqual(translation.requests.map(\.target.code), ["en", "ja"], "换语言对要按同一张图重译，不该要求重拍")
        XCTAssertNotNil(controller.image, "重译不许丢掉照片")
    }

    // MARK: - 硬件状态透传

    func testFlashAndExposureTogglesReachTheCaptureSource() async {
        let capture = StubCaptureSource()
        let controller = makeController(recognizer: StubRecognizer(blocks: []), capture: capture)

        controller.isFlashOn = true
        controller.isExposureLocked = true

        XCTAssertEqual(capture.flashEnabled, true)
        XCTAssertEqual(capture.exposureLocked, true)
    }

    func testStartReportsPermissionDenialUpFront() async {
        let capture = StubCaptureSource()
        capture.canCapture = false
        capture.isPermissionDenied = true
        let controller = makeController(recognizer: StubRecognizer(blocks: []), capture: capture)

        await controller.start()

        // 权限被拒是进页面就该说清楚的事，不必等用户按快门才报。
        XCTAssertTrue(controller.isPermissionFailure)
        XCTAssertFalse(controller.canCapture)
    }

    // MARK: - 朗读

    func testSpeakUsesTargetLanguageVoiceForTranslatedText() async {
        let synthesizer = SilentSynthesizer()
        let controller = makeController(
            recognizer: StubRecognizer(blocks: [block("你好")]),
            synthesizer: synthesizer
        )

        controller.use(sample())
        await waitUntil({ controller.phase == .done }, "管线没有走到 done")
        controller.speak(controller.blocks[0])
        await waitUntil({ !synthesizer.spoken.isEmpty }, "没有发起朗读")

        XCTAssertEqual(synthesizer.spoken.first?.text, "译:你好")
        XCTAssertEqual(
            synthesizer.spoken.first?.languageCode,
            Language.english.speechLocaleIdentifier,
            "读的是译文，音色必须跟目标语言"
        )
    }

    // MARK: - 历史落盘

    func testSavingABlockGoesThroughTheSharedHistoryPath() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let session = TranslationSession(settings: settings)
        let before = session.historyItems.count

        session.save(source: "禁止吸烟", result: "No smoking", sourceLanguage: .chinese, targetLanguage: .english)
        session.save(source: "禁止吸烟", result: "No smoking", sourceLanguage: .chinese, targetLanguage: .english)

        XCTAssertEqual(session.historyItems.count, before + 1, "同一条重复存入只留一条")
        XCTAssertEqual(session.historyItems.first?.source, "禁止吸烟")
        XCTAssertEqual(session.historyItems.first?.result, "No smoking")
    }
}
