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

/// 可切换的翻译引擎。后续接入自研模型与 LLM 翻译时在此扩展。
enum TranslationEngine: String, CaseIterable, Identifiable {
    case google
    case custom
    case llm

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: String(localized: "谷歌翻译")
        case .custom: String(localized: "自研模型")
        case .llm: String(localized: "LLM 翻译")
        }
    }

    var subtitle: String {
        switch self {
        case .google: String(localized: "免费 · 在线翻译")
        case .custom: String(localized: "端侧离线 · 更快更私密")
        case .llm: String(localized: "自带 API Key · 更高质量")
        }
    }

    var isAvailable: Bool {
        self == .google
    }

    func makeService() -> any TranslationService {
        switch self {
        case .google: GoogleTranslateService()
        // 未接入的引擎在 UI 中不可选；防御性回退到谷歌翻译。
        case .custom, .llm: GoogleTranslateService()
        }
    }
}

struct TranslationRequest: Equatable {
    let text: String
    let source: Language
    let target: Language
}

struct TranslationResult: Equatable {
    let text: String
    let detectedLanguage: Language?
    let alternatives: [String]
}

enum TranslationError: LocalizedError, Equatable {
    case network
    case rateLimited
    case serverError(Int)
    case invalidResponse
    case textTooLong

    var errorDescription: String? {
        switch self {
        case .network: String(localized: "网络连接失败，请检查网络后重试")
        case .rateLimited: String(localized: "请求过于频繁，请稍后再试")
        case .serverError(let code): String(localized: "翻译服务暂时不可用（HTTP \(code)）")
        case .invalidResponse: String(localized: "无法解析翻译结果，请重试")
        case .textTooLong: String(localized: "文本过长，请缩短后重试")
        }
    }
}

protocol TranslationService: Sendable {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

/// 进程内翻译缓存：同一引擎、语言对与原文直接复用结果，不再重复请求。
/// 只缓存成功结果，失败永远走重试。
@MainActor
final class TranslationMemoryCache {
    struct Key: Hashable {
        let engineID: String
        let sourceCode: String
        let targetCode: String
        let text: String
    }

    private var storage: [Key: TranslationResult] = [:]
    private var recentKeys: [Key] = []
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func result(for key: Key) -> TranslationResult? {
        guard let result = storage[key] else { return nil }
        touch(key)
        return result
    }

    func store(_ result: TranslationResult, for key: Key) {
        storage[key] = result
        touch(key)
        if storage.count > capacity, let oldest = recentKeys.first {
            recentKeys.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: Key) {
        if let index = recentKeys.firstIndex(of: key) {
            recentKeys.remove(at: index)
        }
        recentKeys.append(key)
    }
}

/// 本地演示译文，UI 测试通过 --uitest-canned-translation 注入，
/// 保持既有测试断言的固定输出。
struct CannedTranslationService: TranslationService {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let translation = cannedTranslation(
            for: request.text,
            sourceCode: request.source.code,
            target: request.target
        )
        return TranslationResult(
            text: translation,
            detectedLanguage: request.source.isAuto ? detectLanguage(of: request.text) : nil,
            alternatives: cannedAlternatives(for: request.text, translation: translation, target: request.target)
        )
    }

    private func cannedTranslation(for text: String, sourceCode: String, target: Language) -> String {
        switch (sourceCode, target.code, text) {
        case ("zh-Hans", "en", "今天的晚霞特别好看，我想和你一起去海边走走。"):
            return "The sunset is especially beautiful today — I'd love to take a walk along the beach with you."
        case ("en", "zh-Hans", "The sunset is especially beautiful today — I'd love to take a walk along the beach with you."):
            return "今天的晚霞特别好看，我想和你一起去海边走走。"
        case ("zh-Hans", "en", "你好"):
            return "Hello"
        case ("en", "zh-Hans", "Good morning"):
            return "早上好"
        case ("zh-Hans", "ja", "谢谢你的款待。"):
            return "おもてなしをありがとう。"
        default:
            return fallbackTranslation(for: text, target: target)
        }
    }

    private func fallbackTranslation(for text: String, target: Language) -> String {
        switch target.code {
        case "en":
            return String(localized: "A natural translation of “\(text)”")
        case "zh-Hans":
            return String(localized: "“\(text)” 的自然译文")
        case "ja":
            return String(localized: "「\(text)」の自然な翻訳")
        default:
            return "[\(target.nativeName)] \(text)"
        }
    }

    private func cannedAlternatives(for text: String, translation: String, target: Language) -> [String] {
        if text.contains("晚霞") && target.code == "en" {
            return [
                "Today's sunset is breathtaking — I'd love to walk along the beach with you.",
                "The evening sky looks especially beautiful today. Shall we take a walk by the sea?"
            ]
        }
        return [
            String(localized: "\(translation) (更自然)"),
            String(localized: "\(translation) (更简洁)")
        ]
    }

    private func detectLanguage(of text: String) -> Language {
        let containsCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
        return containsCJK ? .chinese : .english
    }
}
