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
    var isAdjustingFocus = false
    var isAdjustingExposure = false
    var focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
    var displayZoomFactor: CGFloat = 1
    var minimumDisplayZoomFactor: CGFloat = 0.5
    var maximumDisplayZoomFactor: CGFloat = 5

    var captureError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var flashEnabled: Bool?
    private(set) var requestedFocusPoint: CGPoint?
    private(set) var requestedZoomFactor: CGFloat?
    private(set) var captureCount = 0
    private(set) var isPreviewFrozen = false

    /// 把拍照挂在半空，好在「快门按了、照片还没回来」这一瞬间做断言——
    /// 真机上这段有几百毫秒到一秒多，正是用户看到取景还在动的那段时间。
    var holdsCapture = false
    /// 拍照确实挂住了。不能拿 `captureCount` 顶替：计数在 await 之前就加了，
    /// 那时 continuation 还没建，此刻放行等于放了个空，之后就永远醒不过来。
    private(set) var isCaptureSuspended = false
    private var pendingCapture: CheckedContinuation<Void, Never>?

    func releaseCapture() {
        pendingCapture?.resume()
        pendingCapture = nil
    }

    func start() async { startCount += 1 }
    func stop() { stopCount += 1 }
    func setFlashEnabled(_ enabled: Bool) { flashEnabled = enabled }
    func focusAndMeter(at devicePoint: CGPoint) { requestedFocusPoint = devicePoint }
    func setDisplayZoomFactor(_ factor: CGFloat) { requestedZoomFactor = factor }
    func setPreviewFrozen(_ frozen: Bool) { isPreviewFrozen = frozen }

    /// 测试要摆布"这张照片歪了几格"，所以开成可写的。
    var contentQuarterTurns = 0

    func capturePhoto() async throws -> CapturedPhoto {
        captureCount += 1
        if holdsCapture {
            await withCheckedContinuation { continuation in
                pendingCapture = continuation
                isCaptureSuspended = true
            }
            isCaptureSuspended = false
        }
        if let captureError { throw captureError }
        // 特意不是正方形：这样"照片有没有被偷偷转过"在尺寸上就看得出来。
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        return CapturedPhoto(image: image, contentQuarterTurns: contentQuarterTurns)
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

    // MARK: - 快门时序

    /// 真机上从按下快门到 `didFinishProcessingPhoto` 有几百毫秒到一秒多。
    /// 这段时间里画面必须已经定住，状态也不能谎称在识别——那时手里根本没有图。
    func testShutterFreezesThePreviewBeforeThePhotoArrives() async {
        let capture = StubCaptureSource()
        capture.holdsCapture = true
        let controller = makeController(recognizer: StubRecognizer(blocks: [block("牌子")]), capture: capture)

        controller.capture()
        // 冻结是同步做的：管线的 Task 还没轮上，画面就该定住了。
        XCTAssertTrue(capture.isPreviewFrozen, "快门按下后取景没有立刻冻住")

        // 停在「快门已按、照片没回来」这一刻——真机上用户看到取景还在动的就是这段。
        await waitUntil({ capture.isCaptureSuspended }, "拍照没有挂在半空，前提没立住")
        XCTAssertNil(controller.image, "前提没立住：照片不该已经到手")
        XCTAssertTrue(capture.isPreviewFrozen, "等照片的这段时间里取景又活了")
        XCTAssertEqual(controller.phase, .capturing, "还没有照片就对用户说在识别文字")

        capture.releaseCapture()
        await waitUntil({ controller.phase == .done }, "管线没有走到 done")
        XCTAssertNotNil(controller.image)
        XCTAssertTrue(capture.isPreviewFrozen, "结果已经上屏，取景不该又活过来")
    }

    func testRetakeUnfreezesThePreview() async {
        let capture = StubCaptureSource()
        let controller = makeController(recognizer: StubRecognizer(blocks: [block("牌子")]), capture: capture)

        controller.capture()
        await waitUntil({ controller.phase == .done }, "管线没有走到 done")
        XCTAssertTrue(capture.isPreviewFrozen)

        controller.reset()
        XCTAssertFalse(capture.isPreviewFrozen, "回到取景后画面还冻在上一张的最后一帧")
    }

    /// 拍照本身失败时界面退回取景，取景就必须是活的——否则用户对着一张
    /// 定格的死画面按快门，怎么按都没反应。
    func testCaptureFailureUnfreezesThePreview() async {
        let capture = StubCaptureSource()
        capture.captureError = CameraCaptureError.captureFailed
        let controller = makeController(recognizer: StubRecognizer(), capture: capture)

        controller.capture()
        await waitUntil(
            { if case .failed = controller.phase { return true } else { return false } },
            "拍照失败没有落到失败态"
        )

        XCTAssertNil(controller.image)
        XCTAssertFalse(capture.isPreviewFrozen, "拍照失败后取景还冻着")
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

    /// 横持拍照：照片保持拍下来的样子，识别框却是在转正后的副本里量的，
    /// 所以框必须转回原图坐标才贴得上。
    ///
    /// 数字写死而不是拿 `rotatedClockwise` 反算——那样只能证明"调用发生过"，
    /// 证明不了转的方向对。转错方向会得到另外三组坐标里的一组。
    func testLandscapeCaptureRotatesRecognizedBlocksBackOntoThePhoto() async {
        let capture = StubCaptureSource()
        capture.contentQuarterTurns = 1
        let controller = makeController(
            recognizer: StubRecognizer(blocks: [block("你好", y: 0.6)]),
            capture: capture
        )

        controller.capture()
        await waitUntil({ controller.phase == .done }, "管线没有走到 done")

        XCTAssertEqual(
            controller.image?.size,
            CGSize(width: 40, height: 20),
            "照片被转过了——取景器里什么构图，结果页就该是什么构图"
        )
        guard let quad = controller.blocks.first?.quad else {
            return XCTFail("没有识别块")
        }
        XCTAssertEqual(quad.topLeft.x, 0.65, accuracy: 1e-9)
        XCTAssertEqual(quad.topLeft.y, 0.9, accuracy: 1e-9)
        XCTAssertEqual(quad.angle, -.pi / 2, accuracy: 1e-9, "译文贴片没有跟着躺下来")
    }

    /// 竖持不该被这套东西碰到：圈数为 0 时框原样传下去。
    func testPortraitCaptureLeavesRecognizedBlocksAlone() async {
        let controller = makeController(recognizer: StubRecognizer(blocks: [block("你好", y: 0.6)]))

        controller.capture()
        await waitUntil({ controller.phase == .done }, "管线没有走到 done")

        XCTAssertEqual(controller.blocks.first?.quad, block("你好", y: 0.6).quad)
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

    func testResultImageDisablesAndRejectsAnotherCapture() {
        let capture = StubCaptureSource()
        let controller = makeController(recognizer: StubRecognizer(blocks: []), capture: capture)

        controller.use(sample())
        XCTAssertNotNil(controller.image)
        XCTAssertFalse(controller.canCapture)

        controller.capture()

        XCTAssertEqual(capture.captureCount, 0, "结果态即使绕过界面直接调用，也不能再次拍照")
    }

    func testFirstShutterPressImmediatelyBlocksASecondOne() async {
        let capture = StubCaptureSource()
        let controller = makeController(recognizer: StubRecognizer(blocks: []), capture: capture)

        controller.capture()
        controller.capture()
        await waitUntil({ controller.phase == .done }, "首轮拍照管线没有完成")

        XCTAssertEqual(capture.captureCount, 1, "照片 delegate 回来前也只能有一轮拍照")
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

    func testFlashFocusAndZoomReachTheCaptureSource() async {
        let capture = StubCaptureSource()
        let controller = makeController(recognizer: StubRecognizer(blocks: []), capture: capture)
        let focusPoint = CGPoint(x: 0.25, y: 0.75)

        controller.isFlashOn = true
        controller.focusAndMeter(at: focusPoint)
        controller.setDisplayZoomFactor(4.2)

        XCTAssertEqual(capture.flashEnabled, true)
        XCTAssertEqual(capture.requestedFocusPoint, focusPoint)
        XCTAssertEqual(capture.requestedZoomFactor, 4.2)
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
