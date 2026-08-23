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

/// 系统离线翻译（Translation 框架）作为 `TranslationService`。
///
/// **只在没配中转的构建里出现。** 配了中转就永远走中转——译文质量差别明显，
/// 不能让用户在某次网络抖动时悄无声息地换一个引擎。它的存在是为了让克隆仓库的人
/// 零配置也能把 App 跑起来，而不是给正式包兜底。
///
/// 相应地，这里不实现原生批量。框架有 `translate(batch:)`（返回 AsyncSequence，
/// 逐条流出），但接它要在 `AppleTranslationProvider` 里为 iOS 26+ 直构路径和
/// iOS 18–25 宿主路径各写一套，而那个文件的代际围栏本就微妙。协议的默认实现
/// （并发发单条）在这条兜底路径上够用，不值得为它冒改坏语音管线的风险。
struct AppleBackedTranslationService: TranslationService {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        do {
            let text = try await AppleTranslationProvider.shared.translate(
                request.text,
                source: request.source,
                target: request.target,
                volatilePreferred: false
            )
            return TranslationResult(text: text, detectedLanguage: nil, alternatives: [])
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppleTranslationUnavailableError {
            throw TranslationError.systemTranslationUnavailable(reason: error.reason)
        } catch {
            // 框架自己抛的错（会话失效、语言对被撤等）没有可展示的文案，
            // 统一归到"暂时不可用"，别把 NSError 的描述糊到用户脸上。
            throw TranslationError.systemTranslationUnavailable(
                reason: String(localized: "系统翻译此刻不可用，请稍后再试")
            )
        }
    }
}
