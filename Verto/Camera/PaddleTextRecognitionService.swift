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
/// 与 `tools/build-ocr-models` 里的转换脚本严格对应，改一边必须改另一边。
///
/// 模型不随 app 分发，由 `OCRModelCatalog` 下载安装；本类型只负责用。
final class PaddleTextRecognitionService: TextRecognitionService {
    private let model: InstalledOCRModel
    /// 模型与字表加载一次就常驻。Core ML 编译产物的加载在旧机器上要几百毫秒，
    /// 每次快门都重来会让第一张照片明显变慢。
    private let loaded: LoadedModels

    /// 加载失败（文件被删/损坏/与字表对不上）时抛错，让调用方回落到系统引擎。
    init(model: InstalledOCRModel) throws {
        self.model = model
        loaded = try LoadedModels(model: model)
    }

    private struct LoadedModels {
        let detector: MLModel
        let recognizer: MLModel
        let characters: OCRCharacterSet
        let recognizerClassCount: Int

        init(model: InstalledOCRModel) throws {
            let configuration = MLModelConfiguration()
            // 交给系统在神经引擎/GPU/CPU 之间选。模型是固定形状的，
            // 神经引擎能吃下，实测比纯 CPU 快三倍以上。
            configuration.computeUnits = .all
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

    /// 把模型输出的 `MLMultiArray` 拷成 `[Float]`，并**先验数据类型再动指针**。
    ///
    /// 这不是防御性编程的洁癖：转换脚本一旦漏掉显式的 float32 输出声明，
    /// coremltools 会跟随 fp16 计算精度把输出也标成 float16，而按 float32
    /// 去读那块缓冲就是读两倍长度——直接崩进程，且崩在 Core ML 内部，
    /// 堆栈完全看不出是自己越界。这里宁可抛错也不要再崩一次。
    private static func floats(from array: MLMultiArray, count: Int) throws -> [Float] {
        guard array.count >= count else { throw TextRecognitionError.recognitionFailed }
        switch array.dataType {
        case .float32:
            return array.withUnsafeMutableBytes { raw, _ in
                guard let base = raw.bindMemory(to: Float.self).baseAddress else { return [] }
                return [Float](UnsafeBufferPointer(start: base, count: count))
            }
        case .float16:
            return array.withUnsafeMutableBytes { raw, _ in
                guard let base = raw.bindMemory(to: Float16.self).baseAddress else { return [] }
                return UnsafeBufferPointer(start: base, count: count).map(Float.init)
            }
        default:
            throw TextRecognitionError.recognitionFailed
        }
    }

    func recognizeText(
        in image: CGImage,
        languages: [Language]
    ) async throws -> [RecognizedTextBlock] {
        let canvas = OCRImageCanvas(image: image, side: OCRModelPack.detectorInputSize)
        guard let canvas else { throw TextRecognitionError.recognitionFailed }

        let boxes = try detect(canvas: canvas)
        try Task.checkCancellation()
        guard !boxes.isEmpty else { throw TextRecognitionError.noTextFound }

        var lines: [RecognizedTextBlock] = []
        for box in boxes {
            try Task.checkCancellation()
            guard let crop = canvas.crop(box.corners),
                  let quad = TextDetectionPostProcess.quad(
                    from: box.corners,
                    mapWidth: canvas.scaledWidth, mapHeight: canvas.scaledHeight
                  ) else {
                continue
            }
            let read = try recognize(crop: crop)
            let text = read.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(RecognizedTextBlock(
                text: text, quad: quad, confidence: min(read.confidence, box.score)
            ))
        }

        let blocks = TextBlockGrouping.group(lines: lines)
        guard !blocks.isEmpty else { throw TextRecognitionError.noTextFound }
        return blocks
    }

    // MARK: - 检测

    private func detect(canvas: OCRImageCanvas) throws -> [TextDetectionPostProcess.RotatedBox] {
        let side = OCRModelPack.detectorInputSize
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
                                     dataType: .float32)
        input.withUnsafeMutableBytes { raw, _ in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            canvas.fillDetectorInput(into: base)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
        let output = try loaded.detector.prediction(from: provider)
        guard let name = loaded.detector.modelDescription.outputDescriptionsByName.keys.first,
              let probabilities = output.featureValue(for: name)?.multiArrayValue else {
            throw TextRecognitionError.recognitionFailed
        }

        let values = try Self.floats(from: probabilities, count: side * side)

        return TextDetectionPostProcess.boxes(
            probabilities: values, width: side, height: side,
            // letterbox 补出来的黑边不参与连通域分析，否则黑边会和画面边缘
            // 连成一个覆盖全图的巨框。
            validWidth: canvas.scaledWidth, validHeight: canvas.scaledHeight
        )
    }

    // MARK: - 识别

    private func recognize(crop: OCRLineCrop) throws -> CTCDecoder.Result {
        let height = OCRModelPack.recognizerInputHeight
        let width = OCRModelPack.recognizerInputWidth
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
                                     dataType: .float32)
        input.withUnsafeMutableBytes { raw, _ in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            // 先整体置零：补白区在归一化后就该是 0，与训练时的 padding 一致。
            base.update(repeating: 0, count: 3 * height * width)
            crop.fillRecognizerInput(into: base)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
        let output = try loaded.recognizer.prediction(from: provider)
        guard let name = loaded.recognizer.modelDescription.outputDescriptionsByName.keys.first,
              let logits = output.featureValue(for: name)?.multiArrayValue,
              logits.shape.count == 3 else {
            throw TextRecognitionError.recognitionFailed
        }

        let steps = logits.shape[1].intValue
        let classes = logits.shape[2].intValue
        let values = try Self.floats(from: logits, count: steps * classes)

        // 只解码有效宽度对应的时间步。补白区也会产出预测，一起解码会在行尾
        // 拖出一串重复字符。时间步与输入宽度成正比（模型内部固定下采样 8 倍）。
        let validSteps = max(1, Int((Double(steps) * Double(crop.usedWidth) / Double(width)).rounded()))
        return CTCDecoder.decode(
            probabilities: values, timeSteps: min(validSteps, steps),
            classCount: classes, characterSet: loaded.characters
        )
    }
}
