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
            ScrollView(showsIndicators: false) {
                if filteredItems.isEmpty {
                    emptyState
                        .padding(.horizontal, 18)
                        .padding(.top, 24)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if !items(for: "今天").isEmpty {
                            historySection("今天", items: items(for: "今天"))
                        }
                        if !items(for: "昨天").isEmpty {
                            historySection("昨天", items: items(for: "昨天"))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 30)
                }
            }
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
        HStack(spacing: 0) {
            filterSegment("全部", active: !showFavoritesOnly, identifier: "history-all-filter") {
                showFavoritesOnly = false
            }
            filterSegment(
                "收藏",
                active: showFavoritesOnly,
                systemImage: "star",
                identifier: "history-favorites-filter"
            ) {
                showFavoritesOnly = true
            }
        }
        .padding(3)
        .background(AppTheme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private func filterSegment(
        _ title: String,
        active: Bool,
        systemImage: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                // 调用侧传原始字面量当 key，此处查表渲染。
                Text(LocalizedStringKey(title))
            }
            .font(.system(size: 14, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? AppTheme.ink : AppTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppTheme.card)
                        .softShadow(radius: 4, y: 1, opacity: 0.06)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
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
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title)
                .padding(.horizontal, 4)
                .padding(.top, title == "昨天" ? 8 : 0)

            VStack(spacing: 12) {
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
                }
            }
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
