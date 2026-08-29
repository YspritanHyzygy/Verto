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

import CoreGraphics
import CoreML
import Foundation

/// 基于 PP-OCRv6（转 Core ML）的端侧文字识别。
///
/// 两段式：检测模型给出每行文字的旋转框，识别模型逐行读出文字。前后处理参数
/// 与 `https://github.com/YspritanHyzygy/Verto-Model-Packs/blob/main/scripts/build_models.py`
/// 严格对应，改一边必须改另一边。
///
/// 模型不随 app 分发，由 `OCRModelCatalog` 下载安装；本类型只负责用。
final class PaddleTextRecognitionService: TextRecognitionService {
    /// 正式 App 永远把调度权交给 Core ML。真实模型探针可以显式注入别的值做
    /// 配对实验，但生产调用方都走这个默认值，不按芯片维护第二套策略。
    static let productionComputeUnits: MLComputeUnits = .all

    private let model: InstalledOCRModel
    /// 模型与字表加载一次就常驻。Core ML 编译产物的加载在旧机器上要几百毫秒，
    /// 每次快门都重来会让第一张照片明显变慢。
    private let loaded: LoadedModels

    /// 加载失败（文件被删/损坏/与字表对不上）时抛错，让调用方回落到系统引擎。
    init(
        model: InstalledOCRModel,
        computeUnits: MLComputeUnits = PaddleTextRecognitionService.productionComputeUnits
    ) throws {
        self.model = model
        loaded = try LoadedModels(model: model, computeUnits: computeUnits)
    }

    private struct LoadedModels {
        let detector: MLModel
        let recognizer: MLModel
        let characters: OCRCharacterSet
        let recognizerClassCount: Int

        init(model: InstalledOCRModel, computeUnits: MLComputeUnits) throws {
            let configuration = MLModelConfiguration()
            // 生产默认值是 `.all`，由 Core ML 在 ANE/GPU/CPU 之间调度。这个参数
            // 只给真实模型探针做同机配对测量，不作为用户开关或芯片白名单。
            configuration.computeUnits = computeUnits
            detector = try MLModel(contentsOf: model.detectorURL, configuration: configuration)
            recognizer = try MLModel(contentsOf: model.recognizerURL, configuration: configuration)
            characters = try OCRCharacterSet(contentsOf: model.charactersURL)

            // 字表与模型必须配套：差一位会让整篇结果变成乱码且不报错，
            // 所以宁可在加载时就拒绝，也不要带病上路。
            guard let output = recognizer.modelDescription
                .outputDescriptionsByName.values.first,
                  let shape = output.multiArrayConstraint?.shape,
                  let classes = shape.last?.intValue else {
                throw OCRCharacterSetError.empty
            }
            recognizerClassCount = classes
            guard classes == characters.expectedClassCount else {
                throw OCRCharacterSetError.classCountMismatch(
                    expected: characters.expectedClassCount, actual: classes
                )
            }
        }
    }

    /// 把模型输出的 `MLMultiArray` 拷成稠密行优先的 `[Float]`。
    ///
    /// **必须走 `strides`，不能把缓冲当成连续行优先直接读。** `MLMultiArray`
    /// 不保证连续：神经引擎会把最后一维补齐到 16 的倍数。识别模型输出
    /// `[1, 80, 18710]`，在 ANE 上 strides 是 `[1497600, 18720, 1]`——
    /// 类别维被补到 18720。按 18710 的间距读，第 t 个时间步就偏 `t×10` 个元素，
    /// 越往后越离谱，最后落进补齐区。症状是识别结果变成散落在字表各处的乱码
    /// 加一长串重复字符，而 CPU/GPU 上 strides 恰好是连续的，
    /// **模拟器完全复现不出来**（模拟器没有神经引擎）。这个坑真机上踩过。
    ///
    /// 顺带仍然先验数据类型：转换脚本漏掉显式 float32 输出声明时，
    /// coremltools 会跟随 fp16 计算精度把输出标成 float16，按 float32 读
    /// 就是读两倍长度，直接崩在 Core ML 内部、堆栈看不出是自己越界。
    /// 非 private：`PaddleOCRProbeTests` 要直接喂一个带补齐步长的张量来钉这条规则，
    /// 而真机上才出现的布局在模拟器里造不出来。
    static func denseFloats(from array: MLMultiArray) throws -> [Float] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard !shape.isEmpty, shape.count == strides.count,
              let rowLength = shape.last, rowLength > 0,
              strides.last == 1 else {
            // 最内维步长不为 1 的布局本工程没见过，与其猜着读不如明确失败。
            throw TextRecognitionError.recognitionFailed
        }
        let total = shape.reduce(1, *)
        let rowCount = total / rowLength

        /// 第 r 行在源缓冲里的起点：把 r 按前几维的形状拆开，各维乘自己的 stride。
        func rowOffset(_ r: Int) -> Int {
            var remainder = r, offset = 0
            for dimension in stride(from: shape.count - 2, through: 0, by: -1) {
                let size = shape[dimension]
                guard size > 0 else { continue }
                offset += (remainder % size) * strides[dimension]
                remainder /= size
            }
            return offset
        }

        var out = [Float](repeating: 0, count: total)
        switch array.dataType {
        case .float32:
            array.withUnsafeMutableBytes { raw, _ in
                guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
                out.withUnsafeMutableBufferPointer { destination in
                    guard let target = destination.baseAddress else { return }
                    for r in 0..<rowCount {
                        // 最内维连续，整行 memcpy；补齐出来的空档自然被跳过。
                        (target + r * rowLength).update(from: base + rowOffset(r), count: rowLength)
                    }
                }
            }
        case .float16:
            array.withUnsafeMutableBytes { raw, _ in
                guard let base = raw.bindMemory(to: Float16.self).baseAddress else { return }
                for r in 0..<rowCount {
                    let source = base + rowOffset(r)
                    for c in 0..<rowLength { out[r * rowLength + c] = Float(source[c]) }
                }
            }
        default:
            throw TextRecognitionError.recognitionFailed
        }
        return out
    }

    func recognizeText(
        in image: CGImage,
        languages: [Language]
    ) async throws -> [RecognizedTextBlock] {
        let lines = try await recognizeLines(in: image)
        let blocks = TextBlockGrouping.group(lines: lines)
        guard !blocks.isEmpty else { throw TextRecognitionError.noTextFound }
        return blocks
    }

    /// 与正式识别共用的单行出口。真实图片 benchmark 需要在段落合并前把每个
    /// detector 框与公开数据集的逐行标注匹配；这里不计分，只返回生产链路的原始行。
    func recognizeLines(in image: CGImage) async throws -> [RecognizedTextBlock] {
        let output = try await runPipeline(in: image)
        guard !output.lines.isEmpty else { throw TextRecognitionError.noTextFound }
        return output.lines
    }

    /// 评测和正式识别共用的唯一完整管线。检测框在识别失败时也保留，避免
    /// recognizer 的空结果反过来污染 detector precision/recall。
    struct PipelineOutput {
        let detectionQuads: [TextQuad]
        let lines: [RecognizedTextBlock]
        /// 原始阶段耗时只供外部 benchmark 使用；这里不做阈值判断或 pass/fail。
        let timingsMilliseconds: [String: Double]
    }

    func runPipeline(
        in image: CGImage,
        collectTimings: Bool = false,
        recognizeText: Bool = true
    ) async throws -> PipelineOutput {
        var timings = PipelineTimings()
        let preprocessingStarted = collectTimings ? Date() : nil
        let canvas = OCRImageCanvas(image: image, side: model.detectorInputSize)
        guard let canvas else { throw TextRecognitionError.recognitionFailed }
        timings.preprocessing += Self.elapsedMilliseconds(since: preprocessingStarted)

        let boxes = try detect(
            canvas: canvas, collectTimings: collectTimings, timings: &timings
        )
        try Task.checkCancellation()
        let detectionQuads = boxes.compactMap {
            TextDetectionPostProcess.quad(
                from: $0.corners,
                mapWidth: canvas.scaledWidth,
                mapHeight: canvas.scaledHeight
            )
        }
        if !recognizeText {
            return PipelineOutput(
                detectionQuads: detectionQuads,
                lines: [],
                timingsMilliseconds: [
                    "preprocessing": timings.preprocessing,
                    "detector": timings.detector,
                    "detectionPostProcess": timings.detectionPostProcess,
                    "recognizer": 0,
                    "recognizerPerLine": 0,
                    "decode": 0,
                ]
            )
        }

        var lines: [RecognizedTextBlock] = []
        for box in boxes {
            try Task.checkCancellation()
            let cropStarted = collectTimings ? Date() : nil
            // 三处用途，两个框。裁剪与**定位**用外扩框：DB 给的是文字区域的收缩
            // 多边形，拿它去裁会切掉首尾字母，拿它去贴译文只压得住字的中间一条。
            // 合并判据用紧框：外扩量随长宽比变化，会把行高比和行距都搅乱。
            guard let crop = canvas.crop(
                    box.corners,
                    outputHeight: model.recognizerInputHeight,
                    outputWidth: model.recognizerInputWidth
                  ),
                  let quad = TextDetectionPostProcess.quad(
                    from: box.corners,
                    mapWidth: canvas.scaledWidth, mapHeight: canvas.scaledHeight
                  ),
                  let metricsQuad = TextDetectionPostProcess.quad(
                    from: box.tightCorners,
                    mapWidth: canvas.scaledWidth, mapHeight: canvas.scaledHeight
                  ) else {
                continue
            }
            timings.preprocessing += Self.elapsedMilliseconds(since: cropStarted)
            timings.recognizerAttempts += 1
            let read = try recognize(
                crop: crop, collectTimings: collectTimings, timings: &timings
            )
            let text = read.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let confidence = min(read.confidence, box.score)
            lines.append(RecognizedTextBlock(
                text: text,
                quad: quad,
                metricsQuad: metricsQuad,
                confidence: confidence,
                tokens: Self.tokens(
                    text: read.text,
                    result: read,
                    lineQuad: quad,
                    confidence: confidence
                )
            ))
        }
        var raw = [
            "preprocessing": timings.preprocessing,
            "detector": timings.detector,
            "detectionPostProcess": timings.detectionPostProcess,
            "recognizer": timings.recognizer,
            "decode": timings.decode,
        ]
        raw["recognizerPerLine"] = timings.recognizer / Double(max(1, timings.recognizerAttempts))
        return PipelineOutput(
            detectionQuads: detectionQuads,
            lines: lines,
            timingsMilliseconds: raw
        )
    }

    private struct PipelineTimings {
        var preprocessing = 0.0
        var detector = 0.0
        var detectionPostProcess = 0.0
        var recognizer = 0.0
        var decode = 0.0
        var recognizerAttempts = 0
    }

    private static func elapsedMilliseconds(since started: Date?) -> Double {
        started.map { Date().timeIntervalSince($0) * 1000 } ?? 0
    }

    private static func tokens(
        text: String,
        result: CTCDecoder.Result,
        lineQuad: TextQuad,
        confidence: Float
    ) -> [RecognizedTextToken] {
        guard result.timeSteps > 0, !result.characterSpans.isEmpty else { return [] }
        return TextTokenization.ranges(in: text).compactMap { token in
            let spans = result.characterSpans.filter {
                $0.characterRange.overlaps(token.characterRange)
            }
            guard let first = spans.first, let last = spans.last else { return nil }
            let lower = CGFloat(first.timeStepRange.lowerBound) / CGFloat(result.timeSteps)
            let upper = CGFloat(last.timeStepRange.upperBound) / CGFloat(result.timeSteps)
            return RecognizedTextToken(
                text: token.text,
                quad: lineQuad.horizontalSlice(from: lower, to: upper),
                confidence: confidence
            )
        }
    }

    // MARK: - 检测

    private func detect(
        canvas: OCRImageCanvas,
        collectTimings: Bool,
        timings: inout PipelineTimings
    ) throws -> [TextDetectionPostProcess.RotatedBox] {
        let preprocessingStarted = collectTimings ? Date() : nil
        let side = model.detectorInputSize
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
                                     dataType: .float32)
        input.withUnsafeMutableBytes { raw, _ in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            canvas.fillDetectorInput(
                into: base, mean: model.detectorMean, std: model.detectorStd
            )
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
        timings.preprocessing += Self.elapsedMilliseconds(since: preprocessingStarted)
        let detectorStarted = collectTimings ? Date() : nil
        let output = try loaded.detector.prediction(from: provider)
        timings.detector += Self.elapsedMilliseconds(since: detectorStarted)
        guard let name = loaded.detector.modelDescription.outputDescriptionsByName.keys.first,
              let probabilities = output.featureValue(for: name)?.multiArrayValue else {
            throw TextRecognitionError.recognitionFailed
        }

        let postProcessStarted = collectTimings ? Date() : nil
        defer {
            timings.detectionPostProcess += Self.elapsedMilliseconds(since: postProcessStarted)
        }
        let values = try Self.denseFloats(from: probabilities)
        guard values.count >= side * side else { throw TextRecognitionError.recognitionFailed }

        return TextDetectionPostProcess.boxes(
            probabilities: values, width: side, height: side,
            // letterbox 补出来的黑边不参与连通域分析，否则黑边会和画面边缘
            // 连成一个覆盖全图的巨框。
            validWidth: canvas.scaledWidth, validHeight: canvas.scaledHeight,
            boxScoreThreshold: model.boxScoreThreshold
        )
    }

    // MARK: - 识别

    private func recognize(
        crop: OCRLineCrop,
        collectTimings: Bool,
        timings: inout PipelineTimings
    ) throws -> CTCDecoder.Result {
        let preprocessingStarted = collectTimings ? Date() : nil
        let height = model.recognizerInputHeight
        let width = model.recognizerInputWidth
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
                                     dataType: .float32)
        input.withUnsafeMutableBytes { raw, _ in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            // 先整体置零：补白区在归一化后就该是 0，与训练时的 padding 一致。
            base.update(repeating: 0, count: 3 * height * width)
            crop.fillRecognizerInput(into: base)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
        timings.preprocessing += Self.elapsedMilliseconds(since: preprocessingStarted)
        let recognizerStarted = collectTimings ? Date() : nil
        let output = try loaded.recognizer.prediction(from: provider)
        timings.recognizer += Self.elapsedMilliseconds(since: recognizerStarted)
        guard let name = loaded.recognizer.modelDescription.outputDescriptionsByName.keys.first,
              let logits = output.featureValue(for: name)?.multiArrayValue,
              logits.shape.count == 3 else {
            throw TextRecognitionError.recognitionFailed
        }

        let steps = logits.shape[1].intValue
        let classes = logits.shape[2].intValue

        // 只解码有效宽度对应的时间步。补白区也会产出预测，一起解码会在行尾
        // 拖出一串重复字符。时间步与输入宽度成正比（模型内部固定下采样 8 倍）。
        let validSteps = min(max(1, Int((Double(steps) * Double(crop.usedWidth) / Double(width)).rounded())), steps)
        let decodeStarted = collectTimings ? Date() : nil
        defer { timings.decode += Self.elapsedMilliseconds(since: decodeStarted) }

        // 就地解码，不拷密集数组：这个张量是 1×80×18710，拷一份 5.99MB，
        // 而解码只做逐步 argmax。转换脚本把输出钉成 float32，真机实测的
        // strides 也是 [1497600, 18720, 1]，所以正常走的就是这条零拷贝路径。
        let strides = logits.strides.map(\.intValue)
        if logits.dataType == .float32, strides.count == 3, strides[2] == 1,
           strides[1] >= classes {
            return logits.withUnsafeMutableBytes { raw, _ -> CTCDecoder.Result in
                guard let base = raw.bindMemory(to: Float.self).baseAddress else {
                    return CTCDecoder.Result(text: "", confidence: 0)
                }
                // batch 维恒为 1，所以第 0 维不贡献偏移。
                return CTCDecoder.decode(
                    probabilities: base, stepStride: strides[1],
                    timeSteps: validSteps, classCount: classes,
                    characterSet: loaded.characters
                )
            }
        }

        // 兜底：float16 或非常规布局。没在真机上见过，宁可多拷一次也别猜着读。
        let values = try Self.denseFloats(from: logits)
        guard values.count >= steps * classes else { throw TextRecognitionError.recognitionFailed }
        return CTCDecoder.decode(
            probabilities: values, timeSteps: validSteps,
            classCount: classes, characterSet: loaded.characters
        )
    }
}
