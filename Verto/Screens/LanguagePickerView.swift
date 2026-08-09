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
    @State private var isSearchPresented = false

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
        NavigationStack {
            VStack(spacing: 0) {
                segmentedControl
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
            .navigationTitle("选择语言")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .accessibilityLabel("关闭语言选择")
                        .accessibilityIdentifier("languagePicker.closeButton")
                }
            }
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("搜索语言")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
    }

    private var segmentedControl: some View {
        Picker("语言方向", selection: $effectiveRole) {
            Text(LanguageSelectionRole.target.title)
                .tag(LanguageSelectionRole.target)
                .accessibilityIdentifier("languagePicker.role.target")
            Text(LanguageSelectionRole.source.title)
                .tag(LanguageSelectionRole.source)
                .accessibilityIdentifier("languagePicker.role.source")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(AppTheme.terracotta)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .accessibilityIdentifier("languagePicker.roleSelector")
        .onChange(of: effectiveRole) { _, _ in
            isSearchPresented = true
        }
    }

    private var emptySearchState: some View {
        ContentUnavailableView {
            Label("未找到语言", systemImage: "magnifyingglass")
        } description: {
            Text("请尝试其他名称或语言代码")
        } actions: {
            Button("清除搜索") {
                searchText = ""
                isSearchPresented = true
            }
            .accessibilityIdentifier("languagePicker.emptyState.clearButton")
        }
        .tint(AppTheme.terracotta)
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
