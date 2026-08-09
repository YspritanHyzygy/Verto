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

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: TranslationSession
    let onSelect: (HistoryItem) -> Void

    @State private var showFavoritesOnly = false

    var body: some View {
        VStack(spacing: 0) {
            header
            filterControl
            List {
                if filteredItems.isEmpty {
                    emptyState
                        .listRowInsets(EdgeInsets(top: 24, leading: 18, bottom: 0, trailing: 18))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    if !items(for: "今天").isEmpty {
                        historySection("今天", items: items(for: "今天"))
                    }
                    if !items(for: "昨天").isEmpty {
                        historySection("昨天", items: items(for: "昨天"))
                    }
                }
            }
            .listStyle(.plain)
            // 保留旧列表的 16pt 顶距与 12pt 分区节奏；滚动和分区语义仍由 List 负责。
            .contentMargins(.top, 16, for: .scrollContent)
            .listSectionSpacing(12)
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
        }
        .background(AppTheme.paper.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("历史记录")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(AppTheme.ink)
            Spacer()
            SheetCloseButton { dismiss() }
                .accessibilityIdentifier("history-close-button")
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    private var filterControl: some View {
        Picker("历史记录", selection: $showFavoritesOnly) {
            Text("全部")
                .tag(false)
                .accessibilityIdentifier("history-all-filter")
            Label("收藏", systemImage: "star")
                .tag(true)
                .accessibilityIdentifier("history-favorites-filter")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .tint(AppTheme.terracotta)
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "star.slash")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(AppTheme.faint)
            Text("暂无收藏")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("history-empty-state")
    }

    private func historySection(_ title: String, items: [HistoryItem]) -> some View {
        Section {
            ForEach(items) { item in
                HistoryCard(
                    item: item,
                    onSelect: {
                        onSelect(item)
                        dismiss()
                    },
                    onToggleFavorite: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            session.toggleFavorite(for: item.id)
                        }
                    }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 12, trailing: 18))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        } header: {
            SectionLabel(text: title)
                .padding(.horizontal, 4)
                .padding(.top, title == "昨天" ? 8 : 0)
        }
    }

    private var filteredItems: [HistoryItem] {
        showFavoritesOnly ? session.historyItems.filter(\.isFavorite) : session.historyItems
    }

    private func items(for day: String) -> [HistoryItem] {
        filteredItems.filter { $0.dayLabel == day }
    }
}

private struct HistoryCard: View {
    let item: HistoryItem
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(item.direction)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(AppTheme.faint)
                Spacer()
                Button(action: onToggleFavorite) {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(item.isFavorite ? AppTheme.terracotta : AppTheme.faint)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isFavorite ? "取消收藏" : "加入收藏")
                .accessibilityIdentifier("history-favorite-\(item.id.uuidString)")
            }

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.source)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.secondaryInk)

                    Text(item.result)
                        .font(.system(
                            size: 18,
                            weight: .regular,
                            design: item.targetLanguage.code == "en" ? .serif : .default
                        ))
                        .lineSpacing(3)
                        .foregroundStyle(AppTheme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("载入翻译：\(item.source)")
            .accessibilityIdentifier("history-item-\(item.id.uuidString)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .cardBackground(radius: 18)
    }
}

#Preview {
    HistoryView(session: TranslationSession(), onSelect: { _ in })
}
