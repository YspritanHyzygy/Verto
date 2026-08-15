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

/// 在高精度引擎与系统引擎之间按语言分流。
///
/// 存在的理由是一条硬事实：**PP-OCRv6 三档全部不含谚文**，tiny 档还另外缺日文假名
/// （见 `OCRModelTier.recognizes(_:)`）。整体换掉系统引擎会让韩语识别直接归零，
/// 所以搞不定的语言必须原样交回给 Vision。
///
/// 另外两种回落情形：用户没装任何模型；模型装了但加载失败（文件损坏）。
/// 三种情形都不该让相机页报错——降级到系统引擎仍然能用，只是准确率回到从前。
struct RoutingTextRecognitionService: TextRecognitionService {
    private let highAccuracy: TextRecognitionService?
    private let tier: OCRModelTier?
    private let system: TextRecognitionService

    init(
        highAccuracy: TextRecognitionService?,
        tier: OCRModelTier?,
        system: TextRecognitionService = VisionTextRecognitionService()
    ) {
        self.highAccuracy = highAccuracy
        self.tier = tier
        self.system = system
    }

    /// 给定的识别语言能否全部由高精度模型覆盖。
    ///
    /// 语言列表为空表示自动检测——那时画面里可能是任何文字，包括谚文，
    /// 所以不能赌，交给系统引擎（它的自动检测覆盖面更广）。
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
        guard let highAccuracy,
              Self.canUseHighAccuracy(tier: tier, languages: languages) else {
            return try await system.recognizeText(in: image, languages: languages)
        }
        do {
            return try await highAccuracy.recognizeText(in: image, languages: languages)
        } catch let error as TextRecognitionError where error == .noTextFound {
            // 「没找到文字」是结论不是故障，直接上报；再跑一遍系统引擎只会
            // 让用户多等一秒还是同样的结果。
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 模型跑挂了（文件损坏、内存不足等）不该让整次拍照白费，退回系统引擎。
            return try await system.recognizeText(in: image, languages: languages)
        }
    }
}
