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
import Observation
import SwiftUI
import UIKit

/// 拍照翻译的编排：拍照/选图 → Vision 识别 → 逐块翻译 → 就地叠加。
///
/// 由 AppShell 持有，跨 tab 不销毁——切走再回来，拍过的图和译文都还在。
@Observable
@MainActor
final class PhotoTranslationController {
    enum Phase: Equatable {
        /// 还没有图。
        case idle
        /// 有图待识别（从相册选进来、或拍完还没按识别）。
        case ready
        /// 快门已按下，照片还没交付。这段时间取景已冻住但手里还没有图，
        /// 不能并进 `recognizing`——那会让界面在还没有照片时就说"正在识别文字"。
        case capturing
        case recognizing
        /// 已出块，译文陆续填入。
        case translating
        case done
        case failed(Failure)
    }

    enum Failure: Equatable {
        /// 权限被拒：界面附「前往设置」。
        case permissionDenied(message: String)
        case other(message: String)
    }

    /// 一块文字及其译文。译文异步填充：块先带原文上屏，翻译完成再原地替换
    /// ——同语音气泡「识别永不等翻译」的做法。
    struct TranslatedBlock: Identifiable, Equatable {
        let id: UUID
        let source: String
        var translation: String
        var isPending: Bool
        /// 失败原因。存整个错误而不是一个 Bool——"令牌不对""配额用完""网络断了"
        /// 各要用户做不同的事，都缩成同一个红叹号等于什么都没说。
        var failure: TranslationError?
        let quad: TextQuad
        let lineCount: Int

        var failed: Bool { failure != nil }

        /// 叠加层与详情页显示的文字：译文没到就先显示原文。
        var displayText: String {
            translation.isEmpty ? source : translation
        }
    }

    private(set) var image: UIImage?
    /// 当前这张照片里的世界相对正立顺时针歪了几个 90°（见 `CapturedPhoto`）。
    /// 只有识别那一步用得上；显示与取色永远吃没动过的 `image`。
    private var imageQuarterTurns = 0
    private(set) var blocks: [TranslatedBlock] = []
    private(set) var phase: Phase = .idle

    /// 闪光灯是界面状态，真伪由 captureSource 决定要不要真的作用到硬件。
    var isFlashOn = false {
        didSet { captureSource.setFlashEnabled(isFlashOn) }
    }

    let captureSource: any PhotoCaptureSource

    private let settings: AppSettings
    /// 兜底识别器（默认是系统 Vision）。装了高精度模型时它退居为回落项——
    /// 韩语等模型盖不住的语言、以及模型加载失败时仍然走它。
    private let systemRecognizer: any TextRecognitionService
    /// 高精度模型的安装状态。为 nil 表示这一路完全不启用（UI 测试的罐头路径）。
    private let modelCatalog: OCRModelCatalog?
    private let translationService: (any TranslationService)?
    private let synthesizer: any SpeechSynthesizing
    private let cache = TranslationMemoryCache()

    private var sourceLanguage: Language = .chinese
    private var targetLanguage: Language = .english

    /// 换图/重拍时作废前一轮的全部在途回包。识别与翻译的所有异步收尾都对它取证。
    private var generation = 0
    private var pipelineTask: Task<Void, Never>?
    /// 按去重后的原文索引，不按块 id——同一句话在一张图上出现多次只发一次请求。
    /// 现在只承载块内重试；整页首次翻译走 batchTask。
    private var blockTasks: [String: Task<Void, Never>] = [:]
    /// 整页一次批量提交。分批由 service 按自己的上限决定，这里只管消费流。
    private var batchTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        captureSource: any PhotoCaptureSource,
        recognizer: any TextRecognitionService,
        modelCatalog: OCRModelCatalog? = nil,
        translationService: (any TranslationService)? = nil,
        synthesizer: (any SpeechSynthesizing)? = nil
    ) {
        self.settings = settings
        self.captureSource = captureSource
        self.systemRecognizer = recognizer
        self.modelCatalog = modelCatalog
        self.translationService = translationService
        self.synthesizer = synthesizer ?? SystemSpeechSynthesizer()
    }

    private var activeService: any TranslationService {
        translationService ?? settings.translationEngine.makeService()
    }

    // MARK: - 语言

    func setLanguages(source: Language, target: Language) {
        guard source != sourceLanguage || target != targetLanguage else { return }
        sourceLanguage = source
        targetLanguage = target
        // 已出结果时语言对变了，旧译文即刻失效：留着图重译，不让用户重拍。
        guard image != nil, !blocks.isEmpty else { return }
        retranslateAll()
    }

    /// 识别用的候选语言。「自动检测」不传给 Vision——交给引擎自己判定。
    private var recognitionLanguages: [Language] {
        sourceLanguage.isAuto ? [] : [sourceLanguage]
    }

    // MARK: - 状态展示

    var isBusy: Bool {
        phase == .capturing || phase == .recognizing || phase == .translating
    }

    var isPermissionFailure: Bool {
        if case .failed(.permissionDenied) = phase { return true }
        return false
    }

    var failureMessage: String? {
        guard case .failed(let failure) = phase else { return nil }
        switch failure {
        case .permissionDenied(let message), .other(let message): return message
        }
    }

    /// 快门只在纯取景态可用；已有照片时即使识别结束，也不能从旧按钮位置再开一轮。
    var canCapture: Bool {
        captureSource.canCapture && image == nil && !isBusy
    }

    // MARK: - 生命周期

    func start() async {
        await captureSource.start()
        // 权限被拒是进入页面就该说清楚的事，不必等用户按快门才报。
        if captureSource.isPermissionDenied, image == nil {
            phase = .failed(.permissionDenied(
                message: CameraCaptureError.permissionDenied.errorDescription ?? ""
            ))
        }
    }

    func stop() {
        captureSource.stop()
        synthesizer.stop()
    }

    // MARK: - 用户操作

    func focusAndMeter(at devicePoint: CGPoint) {
        guard image == nil else { return }
        captureSource.focusAndMeter(at: devicePoint)
    }

    func setDisplayZoomFactor(_ factor: CGFloat) {
        guard image == nil else { return }
        captureSource.setDisplayZoomFactor(factor)
    }

    func capture() {
        guard canCapture else { return }
        let generation = beginNewPass()
        // 按下即冻，不等照片回来：交付要几百毫秒到一秒多，画面在这期间继续动
        // 就是"快门没反应"。冻结只作用于预览层，照片该怎么拍还怎么拍。
        captureSource.setPreviewFrozen(true)
        // delegate 回来前 image 仍是 nil，先进入忙态才能挡住连续快门。
        phase = .capturing
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let captured = try await captureSource.capturePhoto()
                let photo = captured.image.normalizedUp()
                guard generation == self.generation else { return }
                self.image = photo
                self.imageQuarterTurns = captured.contentQuarterTurns
                await self.runRecognition(
                    on: photo,
                    quarterTurns: captured.contentQuarterTurns,
                    generation: generation
                )
            } catch {
                guard generation == self.generation else { return }
                self.fail(with: error)
            }
        }
    }

    /// 相册选图：与拍照走同一条识别管线。
    ///
    /// 圈数恒为 0——相册里的图只有 EXIF 一个方向来源，而 `normalizedUp()` 已经把它
    /// 烘进像素了，再没有第二处能说出"这张歪着"。
    func use(_ photo: UIImage) {
        load(photo, quarterTurns: 0)
    }

    /// 整页重来：识别失败后按同一张图再跑一遍。
    ///
    /// 沿用上次的圈数：重试的是同一张照片，方向不会因为重试而改变。
    func retryRecognition() {
        guard let image else { return }
        load(image, quarterTurns: imageQuarterTurns)
    }

    private func load(_ photo: UIImage, quarterTurns: Int) {
        let normalized = photo.normalizedUp()
        let generation = beginNewPass()
        image = normalized
        imageQuarterTurns = quarterTurns
        pipelineTask = Task { [weak self] in
            await self?.runRecognition(
                on: normalized,
                quarterTurns: quarterTurns,
                generation: generation
            )
        }
    }

    /// 丢掉当前照片与译文，回到取景。
    func reset() {
        _ = beginNewPass()
        synthesizer.stop()
        image = nil
        phase = .idle
        // 回到取景就必须解冻，否则下一次进来看到的是上一张的最后一帧。
        captureSource.setPreviewFrozen(false)
    }

    func retryTranslation(for blockID: UUID) {
        guard let block = blocks.first(where: { $0.id == blockID }) else { return }
        let text = normalizedSource(of: block)
        // 同一原文的块共用一次翻译，重试自然也是一起重试。
        for index in blocks.indices where normalizedSource(of: blocks[index]) == text {
            blocks[index].failure = nil
            blocks[index].isPending = true
        }
        phase = .translating
        translate(text: text, generation: generation)
    }

    func speak(_ block: TranslatedBlock) {
        let text = block.displayText
        guard !text.isEmpty else { return }
        let languageCode = block.translation.isEmpty
            ? sourceLanguage.speechLocaleIdentifier
            : targetLanguage.speechLocaleIdentifier
        Task { [synthesizer] in
            await synthesizer.speak(text, languageCode: languageCode)
        }
    }

    /// 存历史用的语言对——供调用方写进共享的 TranslationSession。
    var historyLanguages: (source: Language, target: Language) {
        (sourceLanguage, targetLanguage)
    }

    // MARK: - 管线

    /// 作废上一轮并领取新的代号。所有异步收尾都拿它和 `generation` 比对。
    private func beginNewPass() -> Int {
        pipelineTask?.cancel()
        batchTask?.cancel()
        batchTask = nil
        blockTasks.values.forEach { $0.cancel() }
        blockTasks = [:]
        blocks = []
        generation += 1
        return generation
    }

    private func runRecognition(on photo: UIImage, quarterTurns: Int, generation: Int) async {
        // 进门先验代号：上一轮的任务被 cancel 后仍可能跑到这里一次，
        // 不验会把已经作废的那轮的 phase 写回去。
        guard generation == self.generation else { return }
        guard let cgImage = photo.cgImage else {
            fail(with: TextRecognitionError.recognitionFailed)
            return
        }
        phase = .recognizing

        // 每次拍照重新解析识别器：模型可能刚下载完，也可能刚被用户删掉。
        // catalog 内部按 activeModel 缓存，重复解析不会反复加载 Core ML 模型。
        let recognizer = modelCatalog?.makeRecognizer(system: systemRecognizer) ?? systemRecognizer
        let languages = recognitionLanguages
        // 照片保持拍下来的样子，只把送进识别器的这份副本转正；
        // 出来的框再按同样的圈数转回原图坐标，叠加层与取色才对得上。
        let upright = OCRImageStraightening.straighten(cgImage, quarterTurnsClockwise: quarterTurns)
        do {
            let recognized = try await recognizer.recognizeText(in: upright, languages: languages)
            guard generation == self.generation else { return }
            blocks = recognized.map {
                TranslatedBlock(
                    id: $0.id,
                    source: $0.text,
                    translation: "",
                    isPending: true,
                    failure: nil,
                    quad: $0.quad.rotatedClockwise(quarterTurns: quarterTurns),
                    lineCount: $0.lineCount
                )
            }
            phase = .translating
            startTranslations(generation: generation)
        } catch is CancellationError {
        } catch {
            guard generation == self.generation else { return }
            fail(with: error)
        }
    }

    private func retranslateAll() {
        let generation = self.generation
        batchTask?.cancel()
        batchTask = nil
        blockTasks.values.forEach { $0.cancel() }
        blockTasks = [:]
        for index in blocks.indices {
            blocks[index].translation = ""
            blocks[index].isPending = true
            blocks[index].failure = nil
        }
        phase = .translating
        startTranslations(generation: generation)
    }

    private func startTranslations(generation: Int) {
        // 去重必须在派发前做，不能只靠 cache：一张图上的所有块是同一批发出去的，
        // 谁都还没回来，缓存自然全是 miss——重复的「禁止吸烟」会照发三次。
        var pending: [String] = []
        for text in Set(blocks.map(normalizedSource)) {
            if text.isEmpty {
                finish(text: text, translation: text, failure: nil, generation: generation)
            } else if let cached = cache.result(for: cacheKey(for: text)) {
                // 跨轮复用：重拍同一块牌子、或换回上一个语言对时命中这里。
                finish(text: text, translation: cached.text, failure: nil, generation: generation)
            } else {
                pending.append(text)
            }
        }
        guard !pending.isEmpty else {
            settleIfFinished()
            return
        }

        // 整页一次提交，service 按自己的上限分批；每批回来就填一批。
        // 改造前是每种文本一个独立请求，一张密字图能瞬时打几十个连接。
        let service = activeService
        let source = sourceLanguage
        let target = targetLanguage
        batchTask?.cancel()
        batchTask = Task { [weak self] in
            var settled: Set<String> = []
            for await element in service.translateBatch(pending, source: source, target: target) {
                guard let self, generation == self.generation else { return }
                settled.insert(element.text)
                switch element.result {
                case .success(let result):
                    self.cache.store(result, for: self.cacheKey(for: element.text))
                    self.finish(text: element.text, translation: result.text, failure: nil, generation: generation)
                case .failure(let error):
                    self.finish(text: element.text, translation: "", failure: error, generation: generation)
                }
            }
            // 流结束了却还有没交代的条目：块会永远停在 pending，phase 也永远到不了
            // .done。宁可报一次失败让用户能重试，也不要一个转不完的圈。
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            for text in pending where !settled.contains(text) {
                self.finish(text: text, translation: "", failure: .invalidResponse, generation: generation)
            }
        }
    }

    private func normalizedSource(of block: TranslatedBlock) -> String {
        block.source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cacheKey(for text: String) -> TranslationMemoryCache.Key {
        TranslationMemoryCache.Key(
            engineID: settings.translationEngine.rawValue,
            sourceCode: sourceLanguage.code,
            targetCode: targetLanguage.code,
            text: text
        )
    }

    /// 单条翻译，只用于块内重试——整页首次翻译走 `startTranslations` 的批量路径。
    private func translate(text: String, generation: Int) {
        guard !text.isEmpty else {
            finish(text: text, translation: text, failure: nil, generation: generation)
            return
        }

        let key = cacheKey(for: text)
        if let cached = cache.result(for: key) {
            finish(text: text, translation: cached.text, failure: nil, generation: generation)
            return
        }

        let request = TranslationRequest(text: text, source: sourceLanguage, target: targetLanguage)
        let service = activeService
        blockTasks[text]?.cancel()
        blockTasks[text] = Task { [weak self] in
            do {
                let result = try await service.translate(request)
                guard let self, generation == self.generation else { return }
                self.cache.store(result, for: key)
                self.finish(text: text, translation: result.text, failure: nil, generation: generation)
            } catch is CancellationError {
            } catch {
                guard let self, generation == self.generation else { return }
                self.finish(
                    text: text,
                    translation: "",
                    failure: error as? TranslationError ?? .network,
                    generation: generation
                )
            }
        }
    }

    private func finish(text: String, translation: String, failure: TranslationError?, generation: Int) {
        guard generation == self.generation else { return }
        blockTasks[text] = nil
        for index in blocks.indices where normalizedSource(of: blocks[index]) == text {
            blocks[index].translation = translation
            blocks[index].isPending = false
            blocks[index].failure = failure
        }
        settleIfFinished()
    }

    private func settleIfFinished() {
        guard phase == .translating, !blocks.contains(where: \.isPending) else { return }
        phase = .done
    }

    private func fail(with error: Error) {
        blocks = []
        // 拍照本身就失败时手里没有图，界面退回取景——那就得是活的取景。
        // 识别失败则相反：照片还在屏幕上，取景层根本没在显示，不必解冻。
        if image == nil { captureSource.setPreviewFrozen(false) }
        switch error {
        case CameraCaptureError.permissionDenied:
            phase = .failed(.permissionDenied(
                message: CameraCaptureError.permissionDenied.errorDescription ?? ""
            ))
        default:
            let message = (error as? LocalizedError)?.errorDescription
                ?? TextRecognitionError.recognitionFailed.errorDescription
                ?? ""
            phase = .failed(.other(message: message))
        }
    }
}
