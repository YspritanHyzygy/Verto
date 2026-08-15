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
        var failed: Bool
        let quad: TextQuad
        let lineCount: Int

        /// 叠加层与详情页显示的文字：译文没到就先显示原文。
        var displayText: String {
            translation.isEmpty ? source : translation
        }
    }

    private(set) var image: UIImage?
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
    private var blockTasks: [String: Task<Void, Never>] = [:]

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
        phase == .recognizing || phase == .translating
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

    /// 快门可用：有真实（或合成）采集能力，且当前没有在途识别。
    var canCapture: Bool {
        captureSource.canCapture && !isBusy
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
        guard !isBusy else { return }
        let generation = beginNewPass()
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let photo = try await captureSource.capturePhoto().normalizedUp()
                guard generation == self.generation else { return }
                self.image = photo
                await self.runRecognition(on: photo, generation: generation)
            } catch {
                guard generation == self.generation else { return }
                self.fail(with: error)
            }
        }
    }

    /// 相册选图：与拍照走同一条识别管线。
    func use(_ photo: UIImage) {
        let normalized = photo.normalizedUp()
        let generation = beginNewPass()
        image = normalized
        pipelineTask = Task { [weak self] in
            await self?.runRecognition(on: normalized, generation: generation)
        }
    }

    /// 整页重来：识别失败后按同一张图再跑一遍。
    func retryRecognition() {
        guard let image else { return }
        use(image)
    }

    /// 丢掉当前照片与译文，回到取景。
    func reset() {
        _ = beginNewPass()
        synthesizer.stop()
        image = nil
        phase = .idle
    }

    func retryTranslation(for blockID: UUID) {
        guard let block = blocks.first(where: { $0.id == blockID }) else { return }
        let text = normalizedSource(of: block)
        // 同一原文的块共用一次翻译，重试自然也是一起重试。
        for index in blocks.indices where normalizedSource(of: blocks[index]) == text {
            blocks[index].failed = false
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
        blockTasks.values.forEach { $0.cancel() }
        blockTasks = [:]
        blocks = []
        generation += 1
        return generation
    }

    private func runRecognition(on photo: UIImage, generation: Int) async {
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
        do {
            let recognized = try await recognizer.recognizeText(in: cgImage, languages: languages)
            guard generation == self.generation else { return }
            blocks = recognized.map {
                TranslatedBlock(
                    id: $0.id,
                    source: $0.text,
                    translation: "",
                    isPending: true,
                    failed: false,
                    quad: $0.quad,
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
        blockTasks.values.forEach { $0.cancel() }
        blockTasks = [:]
        for index in blocks.indices {
            blocks[index].translation = ""
            blocks[index].isPending = true
            blocks[index].failed = false
        }
        phase = .translating
        startTranslations(generation: generation)
    }

    private func startTranslations(generation: Int) {
        // 按原文去重后**每种文本**一个独立任务：先到先上屏，单块失败只影响自己
        // （块内可重试），不拖垮整页。
        //
        // 去重必须在派发前做，不能只靠 cache：一张图上的所有块是同一批并发发出的，
        // 谁都还没回来，缓存自然全是 miss——重复的「禁止吸烟」会照发三次。
        for text in Set(blocks.map(normalizedSource)) {
            translate(text: text, generation: generation)
        }
        settleIfFinished()
    }

    private func normalizedSource(of block: TranslatedBlock) -> String {
        block.source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func translate(text: String, generation: Int) {
        guard !text.isEmpty else {
            finish(text: text, translation: text, failed: false, generation: generation)
            return
        }

        let key = TranslationMemoryCache.Key(
            engineID: settings.translationEngine.rawValue,
            sourceCode: sourceLanguage.code,
            targetCode: targetLanguage.code,
            text: text
        )
        // 跨轮复用：重拍同一块牌子、或换回上一个语言对时命中这里。
        if let cached = cache.result(for: key) {
            finish(text: text, translation: cached.text, failed: false, generation: generation)
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
                self.finish(text: text, translation: result.text, failed: false, generation: generation)
            } catch is CancellationError {
            } catch {
                guard let self, generation == self.generation else { return }
                self.finish(text: text, translation: "", failed: true, generation: generation)
            }
        }
    }

    private func finish(text: String, translation: String, failed: Bool, generation: Int) {
        guard generation == self.generation else { return }
        blockTasks[text] = nil
        for index in blocks.indices where normalizedSource(of: blocks[index]) == text {
            blocks[index].translation = translation
            blocks[index].isPending = false
            blocks[index].failed = failed
        }
        settleIfFinished()
    }

    private func settleIfFinished() {
        guard phase == .translating, !blocks.contains(where: \.isPending) else { return }
        phase = .done
    }

    private func fail(with error: Error) {
        blocks = []
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
