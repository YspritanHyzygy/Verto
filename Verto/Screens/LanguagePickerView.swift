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

import SwiftUI

struct LanguagePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let role: LanguageSelectionRole
    @Binding var sourceSelection: Language
    @Binding var targetSelection: Language
    @State private var effectiveRole: LanguageSelectionRole
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    init(
        role: LanguageSelectionRole,
        sourceSelection: Binding<Language>,
        targetSelection: Binding<Language>
    ) {
        self.role = role
        _sourceSelection = sourceSelection
        _targetSelection = targetSelection
        _effectiveRole = State(initialValue: role)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            segmentedControl
            searchBar
            List {
                if hasSearchResults {
                    if showsAutoDetectRow {
                        Section {
                            languageButton(.auto)
                        }
                    }

                    if !filteredRecentLanguages.isEmpty {
                        languageSection("最近使用", languages: filteredRecentLanguages)
                    }

                    if !filteredLanguages.isEmpty {
                        languageSection("全部语言", languages: filteredLanguages)
                    }
                } else {
                    emptySearchState
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, 8, for: .scrollContent)
            .contentMargins(.bottom, 30, for: .scrollContent)
            .listSectionSpacing(8)
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("languagePicker.list")
        }
        .background(AppTheme.paper.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("选择语言")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(AppTheme.ink)
                Text(effectiveRole.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
                    .accessibilityIdentifier("languagePicker.currentRole")
            }

            Spacer()
            SheetCloseButton { dismiss() }
                .accessibilityLabel("关闭语言选择")
                .accessibilityIdentifier("languagePicker.closeButton")
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private var segmentedControl: some View {
        HStack(spacing: 0) {
            segment(role: .target)
            segment(role: .source)
        }
        .padding(3)
        .background(AppTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("语言方向")
        .accessibilityIdentifier("languagePicker.roleSelector")
    }

    private func segment(role segmentRole: LanguageSelectionRole) -> some View {
        let title = segmentRole.title
        let isActive = effectiveRole == segmentRole

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                effectiveRole = segmentRole
            }
            isSearchFocused = true
        } label: {
            Text(title)
                .font(.system(size: 14, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? AppTheme.ink : AppTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    Group {
                        if isActive {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(AppTheme.card)
                                .softShadow(radius: 4, y: 1, opacity: 0.06)
                        }
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "已选择" : "未选择")
        .accessibilityIdentifier("languagePicker.role.\(segmentRole.rawValue)")
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.faint)

            TextField("搜索语言", text: $searchText)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(AppTheme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit {
                    isSearchFocused = false
                }
                .accessibilityLabel("搜索语言")
                .accessibilityHint("可按语言名称或语言代码搜索")
                .accessibilityIdentifier("languagePicker.searchField")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppTheme.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
                .accessibilityIdentifier("languagePicker.clearSearchButton")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .softShadow(radius: 5, y: 1, opacity: 0.04)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var emptySearchState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(AppTheme.faint)

            VStack(spacing: 5) {
                Text("未找到语言")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                Text("请尝试其他名称或语言代码")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(AppTheme.muted)
            }

            Button("清除搜索") {
                searchText = ""
                isSearchFocused = true
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppTheme.terracotta)
            .buttonStyle(.plain)
            .accessibilityIdentifier("languagePicker.emptyState.clearButton")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 86)
        .padding(.horizontal, 30)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("languagePicker.emptyState")
    }

    /// 「自动检测」仅对源语言开放，目标语言列表保持不变。
    private var showsAutoDetectRow: Bool {
        effectiveRole == .source && matchesSearch(.auto)
    }

    private var filteredRecentLanguages: [Language] {
        Language.recent.filter(matchesSearch)
    }

    private var filteredLanguages: [Language] {
        Language.all.filter { language in
            !Language.recent.contains(language) && matchesSearch(language)
        }
    }

    private var hasSearchResults: Bool {
        showsAutoDetectRow || !filteredRecentLanguages.isEmpty || !filteredLanguages.isEmpty
    }

    private func matchesSearch(_ language: Language) -> Bool {
        let query = normalized(searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return true }

        return [language.nativeName, language.localizedName, language.code]
            .map(normalized)
            .contains { $0.contains(query) }
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }

    private func languageSection(_ title: String, languages: [Language]) -> some View {
        Section {
            ForEach(languages) { language in
                languageButton(language)
            }
        } header: {
            SectionLabel(text: title)
                .textCase(nil)
        }
    }

    private func languageButton(_ language: Language) -> some View {
        Button {
            if effectiveRole == .source {
                sourceSelection = language
            } else {
                targetSelection = language
            }
            dismiss()
        } label: {
            LanguageRow(language: language, isSelected: language == activeSelection)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            language.isAuto
                ? Text("自动检测，自动识别输入语言")
                : Text(verbatim: "\(language.nativeName)，\(language.localizedName)")
        )
        .accessibilityValue(language == activeSelection ? "已选择" : "")
        // 整句成对，不做「选择为%@语言」的语序拼接——各语言语序不同。
        .accessibilityHint(effectiveRole == .source ? "选择为翻译自语言" : "选择为翻译到语言")
        .accessibilityIdentifier("languagePicker.language.\(language.code)")
        .listRowInsets(EdgeInsets())
        .listRowBackground(AppTheme.card)
        .listRowSeparatorTint(AppTheme.divider)
    }

    private var activeSelection: Language {
        effectiveRole == .source ? sourceSelection : targetSelection
    }
}

private struct LanguageRow: View {
    let language: Language
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.nativeName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.ink)
                Text(language.localizedName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.faint)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.terracotta)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

#Preview {
    LanguagePickerView(
        role: .target,
        sourceSelection: .constant(.chinese),
        targetSelection: .constant(.english)
    )
}
