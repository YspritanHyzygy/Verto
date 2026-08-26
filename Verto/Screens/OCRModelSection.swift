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

#if OCR_TEST_BUILD
/// OCR Test 专用的人工覆盖入口；生产构建里这个类型根本不参与编译。
struct OCRModelSection: View {
    let catalog: OCRModelCatalog

    var body: some View {
        Section {
            ForEach(OCRTestSelection.allCases) { selection in
                row(for: selection)
                    .accessibilityIdentifier("settings.ocrModel.\(selection.rawValue)")
            }
        } header: {
            SectionLabel(text: "文字识别")
        } footer: {
            footer
        }
    }

    private func row(for selection: OCRTestSelection) -> some View {
        let state = selection.tier.map(catalog.state) ?? .notInstalled
        let isSelected = catalog.testSelection == selection
        return Button {
            catalog.selectTestEngine(selection)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(selection.displayName)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(AppTheme.ink)
                    }
                    Text(subtitle(for: selection, state: state))
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.secondaryInk)
                }
                Spacer(minLength: 8)
                trailing(for: selection, state: state, isSelected: isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(
        for selection: OCRTestSelection,
        state: OCRModelCatalog.State
    ) -> String {
        guard let tier = selection.tier else {
            switch selection {
            case .automatic: return String(localized: "按设备和语言使用生产路由")
            case .vision: return String(localized: "始终使用系统文字识别")
            case .tiny, .small, .medium: return ""
            }
        }
        switch state {
        case .downloading(let progress):
            return String(localized: "正在下载 \(Int(progress * 100))%")
        case .installing:
            return String(localized: "正在安装")
        case .failed(let error):
            return error.errorDescription ?? String(localized: "模型安装失败，请重新下载")
        case .installed:
            return String(localized: "已下载 \(Self.megabytes(tier.downloadBytes)) · 准确率 \(Self.score(tier.accuracy))")
        case .notInstalled:
            return String(localized: "需下载 \(Self.megabytes(tier.downloadBytes)) · 准确率 \(Self.score(tier.accuracy))")
        }
    }

    @ViewBuilder
    private func trailing(
        for selection: OCRTestSelection,
        state: OCRModelCatalog.State,
        isSelected: Bool
    ) -> some View {
        if let tier = selection.tier {
            switch state {
            case .downloading(let progress):
                HStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Button {
                        catalog.cancel(tier)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(AppTheme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("取消下载")
                    .accessibilityIdentifier("settings.ocrModel.\(tier.rawValue).cancel")
                }
            case .installing:
                ProgressView().progressViewStyle(.circular).controlSize(.small)
            case .installed:
                HStack(spacing: 12) {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.terracotta)
                    }
                    Button {
                        catalog.delete(tier)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(AppTheme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除模型")
                    .accessibilityIdentifier("settings.ocrModel.\(tier.rawValue).delete")
                }
            case .notInstalled, .failed:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(AppTheme.terracotta)
                    .accessibilityLabel("下载模型")
            }
        } else if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.terracotta)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("未安装模型时使用系统文字识别。韩语始终使用系统文字识别。")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryInk)
            if catalog.testSelection == .tiny {
                Text("轻量模型不含日文假名，日语使用系统文字识别。")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.secondaryInk)
            }
            Text("精度越高，模型下载体积越大。")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.secondaryInk)
        }
        .padding(.top, 2)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private static func score(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
#endif
