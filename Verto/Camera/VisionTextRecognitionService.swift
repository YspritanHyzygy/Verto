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
import Foundation
import ImageIO
import Vision

/// 端侧 Vision 文字识别。
///
/// 用 `VNRecognizeTextRequest`（iOS 13+）而非 Swift 版 `RecognizeTextRequest`：
/// 后者是 iOS 18+，而本工程部署目标是 17.0，不值得为此抬高门槛。
/// `VNRecognizeTextRequest` 在 iOS 27 SDK 里仍是现役 API，revision3 未废弃。
struct VisionTextRecognitionService: TextRecognitionService {
    /// 低于此置信度的候选丢弃。Vision 在噪点、纹理和反光上会吐出置信度接近 0
    /// 的短乱码；0.3 只砍掉这类纯噪声，正常拍摄的文字即使模糊也远高于它。
    private static let minimumConfidence: Float = 0.3

    func recognizeText(
        in image: CGImage,
        languages: [Language]
    ) async throws -> [RecognizedTextBlock] {
        // 本类型非 actor 隔离，async 方法体在全局并发执行器上跑，
        // Vision 的同步 perform 不会卡主线程，无需再套队列。
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let requested = languages.filter { !$0.isAuto }.map(\.visionRecognitionLanguage)
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let usable = supported.isEmpty ? requested : requested.filter(supported.contains)
        // 指定语言一个都不被支持时不能就这么按默认英文识别——那会把中文识成乱码
        // 且毫无提示。只有调用方本来就没指定语言（自动检测）才允许交给引擎。
        if !requested.isEmpty && usable.isEmpty {
            throw TextRecognitionError.unsupportedLanguage
        }
        request.recognitionLanguages = usable
        // 自动检测（未指定语言）时让引擎自己判定；已指定语言时 recognitionLanguages
        // 就是权威，再开自动检测会让引擎在低置信度时改判到别的语言。
        request.automaticallyDetectsLanguage = usable.isEmpty

        // 入参约定为正立图，方向固定 .up；方向已在 normalizedUp() 里烘进像素。
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            throw TextRecognitionError.recognitionFailed
        }
        try Task.checkCancellation()

        let lines = (request.results ?? []).compactMap(Self.line(from:))
        let blocks = TextBlockGrouping.group(lines: lines)
        guard !blocks.isEmpty else { throw TextRecognitionError.noTextFound }
        return blocks
    }

    private static func line(from observation: VNRecognizedTextObservation) -> RecognizedTextBlock? {
        guard let candidate = observation.topCandidates(1).first,
              candidate.confidence >= minimumConfidence else {
            return nil
        }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return RecognizedTextBlock(
            text: text,
            // VNRectangleObservation 的四角本就是 Vision 归一化坐标（原点左下），
            // 与 TextQuad 同系，直接抄，不做任何翻转。
            quad: TextQuad(
                topLeft: observation.topLeft,
                topRight: observation.topRight,
                bottomRight: observation.bottomRight,
                bottomLeft: observation.bottomLeft
            ),
            confidence: candidate.confidence
        )
    }
}
