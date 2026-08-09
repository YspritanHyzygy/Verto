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
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                engineSection
                voicePlaybackSection
                preferenceSection
                appearanceSection

                footer
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .formStyle(.grouped)
            .contentMargins(.top, 16, for: .scrollContent)
            .contentMargins(.bottom, 30, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("settings.form")
        }
        .background(AppTheme.paper.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(AppTheme.ink)

            Spacer()
            SheetCloseButton { dismiss() }
                .accessibilityLabel("关闭设置")
                .accessibilityIdentifier("settings.closeButton")
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    // 手写 Row 自己负责内边距；inline Picker 要让 Form inset 同时约束标签和系统勾。
    private var engineSection: some View {
        Section {
            Picker("翻译模型", selection: $settings.translationEngine) {
                ForEach(TranslationEngine.allCases) { engine in
                    EngineRow(engine: engine)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.engine.\(engine.rawValue)")
                        .tag(engine)
                        .disabled(!engine.isAvailable)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .tint(AppTheme.terracotta)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(AppTheme.card)
            .listRowSeparatorTint(AppTheme.divider)
        } header: {
            SectionLabel(text: "翻译模型")
                .textCase(nil)
        }
    }

    private var voicePlaybackSection: some View {
        Section {
            ForEach(VoicePlaybackMode.allCases) { mode in
                Button {
                    select(mode)
                } label: {
                    SelectableRow(
                        title: mode.displayName,
                        subtitle: mode.subtitle,
                        isSelected: settings.voicePlaybackMode == mode
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.displayName)，\(mode.subtitle)")
                .accessibilityValue(settings.voicePlaybackMode == mode ? "已选择" : "")
                .accessibilityIdentifier("settings.voicePlayback.\(mode.rawValue)")
                .listRowInsets(EdgeInsets())
                .listRowBackground(AppTheme.card)
                .listRowSeparatorTint(AppTheme.divider)
            }
        } header: {
            SectionLabel(text: "语音对话")
                .textCase(nil)
        }
    }

    private var preferenceSection: some View {
        Section {
            ToggleRow(
                title: String(localized: "翻译后自动朗读译文"),
                subtitle: String(localized: "完成翻译后自动播放语音"),
                isOn: $settings.autoSpeaksTranslation
            )
            .accessibilityIdentifier("settings.autoSpeakToggle")
            .listRowInsets(EdgeInsets())
            .listRowBackground(AppTheme.card)
            .listRowSeparatorTint(AppTheme.divider)
        } header: {
            SectionLabel(text: "通用偏好")
                .textCase(nil)
        }
    }

    private var appearanceSection: some View {
        Section {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    select(mode)
                } label: {
                    SelectableRow(
                        title: mode.displayName,
                        subtitle: mode.subtitle,
                        isSelected: settings.appearanceMode == mode
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.displayName)，\(mode.subtitle)")
                .accessibilityValue(settings.appearanceMode == mode ? "已选择" : "")
                .accessibilityIdentifier("settings.appearance.\(mode.rawValue)")
                .listRowInsets(EdgeInsets())
                .listRowBackground(AppTheme.card)
                .listRowSeparatorTint(AppTheme.divider)
            }
        } header: {
            SectionLabel(text: "外观")
                .textCase(nil)
        }
    }

    private var footer: some View {
        Text("译境 · 版本 1.0")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppTheme.faint)
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
    }

    private func select(_ mode: VoicePlaybackMode) {
        guard settings.voicePlaybackMode != mode else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        settings.voicePlaybackMode = mode
    }

    private func select(_ mode: AppearanceMode) {
        guard settings.appearanceMode != mode else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        settings.appearanceMode = mode
    }
}

private struct EngineRow: View {
    let engine: TranslationEngine

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(engine.isAvailable ? AppTheme.ink : AppTheme.faint)
                Text(engine.subtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.faint)
            }

            Spacer()

            if !engine.isAvailable {
                Text("即将推出")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.inset, in: Capsule())
            }
        }
        .padding(.vertical, 14)
    }
}

private struct SelectableRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.ink)
                Text(subtitle)
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

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.ink)
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.faint)
            }
        }
        // sheet 不继承 TabView 的 tint，不指定会落回系统绿色。
        .tint(AppTheme.terracotta)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

#Preview {
    SettingsView(settings: AppSettings())
}
