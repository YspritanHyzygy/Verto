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

/// 在有序的 PP-OCR 候选链与系统引擎之间按语言分流。
///
/// 存在的理由是一条硬事实：**PP-OCRv6 三档全部不含谚文**，tiny 档还另外缺日文假名
/// （见 `OCRModelTier.recognizes(_:)`）。整体换掉系统引擎会让韩语识别直接归零，
/// 所以搞不定的语言必须原样交回给 Vision。
///
struct RoutingTextRecognitionService: TextRecognitionService {
    struct ModelCandidate: Sendable {
        let tier: OCRModelTier
        let service: any TextRecognitionService
    }

    private let models: [ModelCandidate]
    private let system: TextRecognitionService
    private let languageScout: any ImageLanguageScouting
    private let onModelFailure: @Sendable (OCRModelTier) -> Void

    init(
        models: [ModelCandidate],
        system: TextRecognitionService = VisionTextRecognitionService(),
        languageScout: any ImageLanguageScouting = VisionImageLanguageScout(),
        onModelFailure: @escaping @Sendable (OCRModelTier) -> Void = { _ in }
    ) {
        self.models = models
        self.system = system
        self.languageScout = languageScout
        self.onModelFailure = onModelFailure
    }

    /// 给定的识别语言能否全部由高精度模型覆盖。
    ///
    /// 语言列表为空表示尚未侦察，不能直接声称模型可用。
    static func canUseHighAccuracy(tier: OCRModelTier?, languages: [Language]) -> Bool {
        guard let tier else { return false }
        let requested = languages.filter { !$0.isAuto }
        guard !requested.isEmpty else { return false }
        return requested.allSatisfy(tier.recognizes)
    }

    func recognizeText(
        in image: CGImage,
        languages: [Language]
    ) async throws -> [RecognizedTextBlock] {
        let requested = languages.filter { !$0.isAuto }
        if !requested.isEmpty {
            let supported = models.filter { candidate in
                requested.allSatisfy(candidate.tier.recognizes)
            }
            return try await recognize(
                in: image,
                modelLanguages: requested,
                systemLanguages: languages,
                candidates: supported
            )
        }

        switch await languageScout.decideEngine(for: image) {
        case .vision:
            return try await system.recognizeText(in: image, languages: [])
        case .model(let detectedLanguage):
            let supported = models.filter { $0.tier.recognizes(detectedLanguage) }
            return try await recognize(
                in: image,
                modelLanguages: [detectedLanguage],
                systemLanguages: [],
                candidates: supported
            )
        }
    }

    private func recognize(
        in image: CGImage,
        modelLanguages: [Language],
        systemLanguages: [Language],
        candidates: [ModelCandidate]
    ) async throws -> [RecognizedTextBlock] {
        for candidate in candidates {
            do {
                return try await candidate.service.recognizeText(
                    in: image,
                    languages: modelLanguages
                )
            } catch let error as TextRecognitionError where error == .noTextFound {
                // 「没找到文字」是有效结论，不是拿备用模型再赌一遍的故障。
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 当前会话不再使用这个模型；下一档仍能接手当前照片。
                onModelFailure(candidate.tier)
            }
        }
        return try await system.recognizeText(in: image, languages: systemLanguages)
    }
}
