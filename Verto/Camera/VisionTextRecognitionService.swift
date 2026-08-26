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
import NaturalLanguage
import Vision

enum ImageLanguageScoutDecision: Equatable, Sendable {
    case model(Language)
    case vision
}

protocol ImageLanguageScouting: Sendable {
    func decideEngine(for image: CGImage) async -> ImageLanguageScoutDecision
}

/// 自动源语言只做一次低成本侦察，输出“某个受支持语言可交给模型”或“保守用 Vision”。
/// 它不修改翻译请求的 `.auto`，也不把侦察文字当最终 OCR 结果。
struct VisionImageLanguageScout: ImageLanguageScouting {
    func decideEngine(for image: CGImage) async -> ImageLanguageScoutDecision {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true

        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            return .vision
        }
        guard !Task.isCancelled else { return .vision }
        let candidates = (request.results ?? []).compactMap { observation -> String? in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= 0.3 else { return nil }
            return candidate.string
        }
        let text = candidates.joined(separator: "\n")
        guard !text.isEmpty else { return .vision }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Language.all.map { NLLanguage(rawValue: $0.code) }
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: Language.all.count)
            .reduce(into: [String: Double]()) { result, item in
                result[item.key.rawValue] = item.value
            }
        return ImageLanguageAssessment.decide(text: text, hypotheses: hypotheses)
    }
}

/// 与 Vision 调用解耦的纯判定，测试可以直接覆盖短文本、混合脚本和低置信度。
enum ImageLanguageAssessment {
    /// 对短招牌来说 0.5 左右常只是“几种拉丁语言都差不多”。0.65 再加 0.15
    /// 的领先差值宁可多走一次 Vision，也不把猜测当成模型覆盖事实。
    private static let minimumProbability = 0.65
    private static let minimumLead = 0.15

    static func decide(
        text: String,
        hypotheses: [String: Double]
    ) -> ImageLanguageScoutDecision {
        let scripts = scriptCoverage(in: text)
        guard scripts.hasSupportedLetters, !scripts.hasUnsupportedLetters else { return .vision }

        let ranked = hypotheses.compactMap { code, probability -> (Language, Double)? in
            guard let language = supportedLanguage(for: code) else { return nil }
            return (language, probability)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first,
              best.1 >= minimumProbability,
              best.1 - (ranked.dropFirst().first?.1 ?? 0) >= minimumLead else {
            return .vision
        }
        // 假名是明确的日文信号；如果统计分类器却说成中文，说明这段侦察不可靠。
        if scripts.hasKana, best.0.code != Language.japanese.code { return .vision }
        return .model(best.0)
    }

    private static func supportedLanguage(for code: String) -> Language? {
        switch code {
        case "zh", "zh-Hans", "zh-CN": .chinese
        case "en", "en-US": .english
        case "ja", "ja-JP": .japanese
        case "ko", "ko-KR": Language.all.first { $0.code == "ko" }
        case "fr", "fr-FR": Language.all.first { $0.code == "fr" }
        case "es", "es-ES": Language.all.first { $0.code == "es" }
        case "de", "de-DE": Language.all.first { $0.code == "de" }
        default: nil
        }
    }

    private static func scriptCoverage(
        in text: String
    ) -> (hasSupportedLetters: Bool, hasKana: Bool, hasUnsupportedLetters: Bool) {
        var hasSupported = false
        var hasKana = false
        var hasUnsupported = false
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            let value = scalar.value
            if isKana(value) {
                hasSupported = true
                hasKana = true
            } else if isLatin(value) || isHan(value) {
                hasSupported = true
            } else {
                // 谚文、阿拉伯文、西里尔文等都落到这里；只要混进一个不覆盖的
                // 字母，整张图就交给 Vision，避免局部乱码伪装成成功。
                hasUnsupported = true
            }
        }
        return (hasSupported, hasKana, hasUnsupported)
    }

    private static func isLatin(_ value: UInt32) -> Bool {
        (0x0041...0x024F).contains(value)
            || (0x1E00...0x1EFF).contains(value)
            || (0x2C60...0x2C7F).contains(value)
            || (0xA720...0xA7FF).contains(value)
            || (0xAB30...0xAB6F).contains(value)
    }

    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x323AF).contains(value)
    }

    private static func isKana(_ value: UInt32) -> Bool {
        (0x3040...0x30FF).contains(value)
            || (0x31F0...0x31FF).contains(value)
            || (0xFF66...0xFF9D).contains(value)
    }
}

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
