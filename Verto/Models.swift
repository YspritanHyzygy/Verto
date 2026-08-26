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

enum AppMode: String, CaseIterable, Identifiable {
    case text
    case voice
    case camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: String(localized: "文字")
        case .voice: String(localized: "语音")
        case .camera: String(localized: "相机")
        }
    }

    var systemImage: String {
        switch self {
        case .text: "textformat"
        case .voice: "mic"
        case .camera: "camera"
        }
    }
}

enum LanguageSelectionRole: String, Identifiable {
    case source
    case target

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: String(localized: "源语言")
        case .target: String(localized: "目标语言")
        }
    }
}

enum SheetDestination: Identifiable {
    case language(LanguageSelectionRole)
    case history
    case settings

    var id: String {
        switch self {
        case .language(let role): "language-\(role.rawValue)"
        case .history: "history"
        case .settings: "settings"
        }
    }
}

struct Language: Identifiable, Equatable, Hashable, Sendable {
    let code: String
    let nativeName: String
    /// 按当前界面语言显示的注解名（如英文界面下的 "English (US)" 之于 "英语"）。
    let localizedName: String

    var id: String { code }

    static let chinese = Language(code: "zh-Hans", nativeName: "中文", localizedName: String(localized: "简体中文"))
    static let english = Language(code: "en", nativeName: "English", localizedName: String(localized: "英语"))
    static let japanese = Language(code: "ja", nativeName: "日本語", localizedName: String(localized: "日语"))

    /// 仅作为源语言使用；不进入 all/recent，因而不会出现在目标语言列表里。
    static let auto = Language(code: "auto", nativeName: String(localized: "自动检测"), localizedName: String(localized: "自动识别输入语言"))

    var isAuto: Bool { code == "auto" }

    static let recent: [Language] = [.english, .chinese]

    static let all: [Language] = [
        .english,
        .chinese,
        .japanese,
        Language(code: "ko", nativeName: "한국어", localizedName: String(localized: "韩语")),
        Language(code: "fr", nativeName: "Français", localizedName: String(localized: "法语")),
        Language(code: "es", nativeName: "Español", localizedName: String(localized: "西班牙语")),
        Language(code: "de", nativeName: "Deutsch", localizedName: String(localized: "德语"))
    ]
}

struct TextTranslationDraft {
    var sourceText: String
    var sourceLanguage: Language
    var targetLanguage: Language
}

struct ConversationTurn: Identifiable {
    enum Speaker {
        case source
        case target
    }

    let id: UUID
    let speaker: Speaker
    let language: String
    let original: String
    /// 权威译文异步填充：识别不等翻译（live translate 的关键），
    /// 定稿气泡先带粗译/占位上屏，翻译完成后原地替换。
    var translation: String
    /// 权威翻译进行中（气泡译文降透明度显示）。
    var isTranslationPending = false
    /// 权威翻译失败（气泡内提供重试）。
    var translationFailed = false
    /// 译文所属语言的 BCP-47 代码，供气泡朗读选择 TTS 音色；演示数据为 nil。
    let translationLanguageCode: String?

    init(
        id: UUID = UUID(),
        speaker: Speaker,
        language: String,
        original: String,
        translation: String,
        translationLanguageCode: String? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.language = language
        self.original = original
        self.translation = translation
        self.translationLanguageCode = translationLanguageCode
    }

    static let samples: [ConversationTurn] = [
        ConversationTurn(
            speaker: .source,
            language: "English",
            original: "Excuse me, where's the nearest subway station?",
            translation: "请问，最近的地铁站在哪里？"
        ),
        ConversationTurn(
            speaker: .target,
            language: "中文",
            original: "往前走两个路口，地铁站就在右手边。",
            translation: "Go straight for two blocks, the station is on your right."
        ),
        ConversationTurn(
            speaker: .source,
            language: "English",
            original: "Perfect, thank you so much!",
            translation: "太好了，非常感谢！"
        )
    ]
}

struct HistoryItem: Identifiable, Equatable {
    let id: UUID
    let dayLabel: String
    let sourceLanguage: Language
    let targetLanguage: Language
    let source: String
    let result: String
    var isFavorite: Bool

    var direction: String {
        "\(sourceLanguage.nativeName) → \(targetLanguage.nativeName)"
    }

    init(
        id: UUID = UUID(),
        dayLabel: String,
        sourceLanguage: Language,
        targetLanguage: Language,
        source: String,
        result: String,
        isFavorite: Bool
    ) {
        self.id = id
        self.dayLabel = dayLabel
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.source = source
        self.result = result
        self.isFavorite = isFavorite
    }

    static let today: [HistoryItem] = [
        HistoryItem(
            dayLabel: "今天",
            sourceLanguage: .chinese,
            targetLanguage: .english,
            source: "今天的晚霞特别好看。",
            result: "The sunset is especially beautiful today.",
            isFavorite: true
        ),
        HistoryItem(
            dayLabel: "今天",
            sourceLanguage: .english,
            targetLanguage: .chinese,
            source: "Where's the nearest subway station?",
            result: "最近的地铁站在哪里？",
            isFavorite: false
        )
    ]

    static let yesterday: [HistoryItem] = [
        HistoryItem(
            dayLabel: "昨天",
            sourceLanguage: .chinese,
            targetLanguage: .japanese,
            source: "谢谢你的款待。",
            result: "おもてなしをありがとう。",
            isFavorite: false
        )
    ]
}

enum TranslationPhase: Equatable {
    case idle
    case loading
    case failed(TranslationError)
}

@Observable
@MainActor
final class TranslationSession {
    var sourceLanguage: Language = .chinese
    var targetLanguage: Language = .english
    var sourceText = "今天的晚霞特别好看，我想和你一起去海边走走。"
    var translatedText = "The sunset is especially beautiful today — I'd love to take a walk along the beach with you."
    var historyItems: [HistoryItem] = HistoryItem.today + HistoryItem.yesterday
    var phase: TranslationPhase = .idle
    var detectedLanguage: Language?
    /// 当前译文的全部候选（首元素即主译文），供「其他译法」选择。
    var translationCandidates: [String] = [
        "The sunset is especially beautiful today — I'd love to take a walk along the beach with you.",
        "Today's sunset is breathtaking — I'd love to walk along the beach with you.",
        "The evening sky looks especially beautiful today. Shall we take a walk by the sea?"
    ]
    private(set) var translationTask: Task<Void, Never>?

    let settings: AppSettings
    private let serviceOverride: (any TranslationService)?
    private let cache = TranslationMemoryCache()

    init(settings: AppSettings = AppSettings(), service: (any TranslationService)? = nil) {
        self.settings = settings
        self.serviceOverride = service
        // 首次启动保留演示内容；此后按上次使用的语言对空白开始，
        // 启动阶段不发起任何网络请求。
        if let storedSource = settings.storedSourceLanguage,
           let storedTarget = settings.storedTargetLanguage {
            sourceLanguage = storedSource
            targetLanguage = storedTarget
            sourceText = ""
            translatedText = ""
            translationCandidates = []
        }
    }

    private var activeService: any TranslationService {
        serviceOverride ?? settings.translationEngine.makeService()
    }

    var characterCount: Int {
        sourceText.filter { !$0.isWhitespace }.count
    }

    var hasAlternatives: Bool {
        translationCandidates.count > 1
    }

    var isSwapEnabled: Bool {
        phase != .loading && (!sourceLanguage.isAuto || detectedLanguage != nil)
    }

    var sourceDisplayName: String {
        guard sourceLanguage.isAuto, let detectedLanguage else {
            return sourceLanguage.nativeName
        }
        return String(localized: "\(detectedLanguage.nativeName) · 已检测")
    }

    /// 历史与收藏中不落「自动检测」——已检测出语言时按检测结果记录。
    private var resolvedSourceLanguage: Language {
        sourceLanguage.isAuto ? (detectedLanguage ?? sourceLanguage) : sourceLanguage
    }

    var isCurrentFavorite: Bool {
        historyItems.first {
            $0.source == sourceText
                && $0.result == translatedText
                && $0.sourceLanguage == resolvedSourceLanguage
                && $0.targetLanguage == targetLanguage
        }?.isFavorite == true
    }

    func makeTextDraft() -> TextTranslationDraft {
        TextTranslationDraft(
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    func commitAndTranslate(_ draft: TextTranslationDraft) {
        sourceText = draft.sourceText
        if draft.sourceLanguage != sourceLanguage {
            detectedLanguage = nil
        }
        sourceLanguage = draft.sourceLanguage
        targetLanguage = draft.targetLanguage
        refreshTranslation()
    }

    func clearCurrent() {
        sourceText = ""
        refreshTranslation()
    }

    func refreshTranslation() {
        translationTask?.cancel()
        translationTask = nil

        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            translatedText = ""
            translationCandidates = []
            detectedLanguage = nil
            phase = .idle
            return
        }

        let cacheKey = TranslationMemoryCache.Key(
            engineID: settings.translationEngine.rawValue,
            sourceCode: sourceLanguage.code,
            targetCode: targetLanguage.code,
            text: text
        )
        if let cached = cache.result(for: cacheKey) {
            apply(cached)
            return
        }

        phase = .loading
        translatedText = ""
        translationCandidates = []
        if sourceLanguage.isAuto {
            detectedLanguage = nil
        }

        let request = TranslationRequest(text: text, source: sourceLanguage, target: targetLanguage)
        let service = activeService
        translationTask = Task {
            do {
                let result = try await service.translate(request)
                guard !Task.isCancelled else { return }
                cache.store(result, for: cacheKey)
                apply(result)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed((error as? TranslationError) ?? .network)
            }
        }
    }

    private func apply(_ result: TranslationResult) {
        translatedText = result.text
        translationCandidates = [result.text] + result.alternatives.filter { $0 != result.text }
        detectedLanguage = sourceLanguage.isAuto ? result.detectedLanguage : nil
        phase = .idle
    }

    func swapLanguages() {
        let newTarget: Language
        if sourceLanguage.isAuto {
            // 自动检测尚未得出结果时无从交换。
            guard let detectedLanguage else { return }
            newTarget = detectedLanguage
        } else {
            newTarget = sourceLanguage
        }
        sourceLanguage = targetLanguage
        targetLanguage = newTarget
        sourceText = translatedText
        detectedLanguage = nil
        refreshTranslation()
    }

    func select(_ language: Language, for role: LanguageSelectionRole) {
        if role == .source {
            if language != sourceLanguage {
                detectedLanguage = nil
            }
            sourceLanguage = language
        } else {
            targetLanguage = language
        }
        refreshTranslation()
    }

    func saveCurrent(favorite: Bool? = nil) {
        save(
            source: sourceText,
            result: translatedText,
            sourceLanguage: resolvedSourceLanguage,
            targetLanguage: targetLanguage,
            favorite: favorite
        )
    }

    /// 写入历史（已存在同条则只更新收藏态）。文字页与相机页共用这一份去重与插入逻辑。
    func save(
        source: String,
        result: String,
        sourceLanguage: Language,
        targetLanguage: Language,
        favorite: Bool? = nil
    ) {
        guard !source.isEmpty, !result.isEmpty else { return }
        if let index = historyItems.firstIndex(where: {
            $0.source == source
                && $0.result == result
                && $0.sourceLanguage == sourceLanguage
                && $0.targetLanguage == targetLanguage
        }) {
            if let favorite {
                historyItems[index].isFavorite = favorite
            }
            return
        }

        historyItems.insert(
            HistoryItem(
                dayLabel: "今天",
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                source: source,
                result: result,
                isFavorite: favorite ?? false
            ),
            at: 0
        )
    }

    func toggleFavorite(for id: UUID) {
        guard let index = historyItems.firstIndex(where: { $0.id == id }) else { return }
        historyItems[index].isFavorite.toggle()
    }

    func toggleCurrentFavorite() {
        saveCurrent(favorite: !isCurrentFavorite)
    }

    func load(_ item: HistoryItem) {
        translationTask?.cancel()
        translationTask = nil
        sourceLanguage = item.sourceLanguage
        targetLanguage = item.targetLanguage
        sourceText = item.source
        translatedText = item.result
        translationCandidates = [item.result]
        detectedLanguage = nil
        phase = .idle
    }
}
