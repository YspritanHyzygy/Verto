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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "翻译模型")
                        .padding(.horizontal, 4)
                    engineCard

                    SectionLabel(text: "语音对话")
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                    voicePlaybackCard

                    SectionLabel(text: "通用偏好")
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                    preferenceCard

                    SectionLabel(text: "外观")
                        .padding(.horizontal, 4)
                        .padding(.top, 14)
                    appearanceCard

                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 30)
            }
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

    private var engineCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(TranslationEngine.allCases.enumerated()), id: \.element.id) { index, engine in
                Button {
                    select(engine)
                } label: {
                    EngineRow(engine: engine, isSelected: settings.translationEngine == engine)
                }
                .buttonStyle(.plain)
                .disabled(!engine.isAvailable)
                .accessibilityLabel("\(engine.displayName)，\(engine.subtitle)")
                .accessibilityValue(accessibilityValue(for: engine))
                .accessibilityIdentifier("settings.engine.\(engine.rawValue)")

                if index < TranslationEngine.allCases.count - 1 {
                    Rectangle()
                        .fill(AppTheme.divider)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
            }
        }
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .softShadow(radius: 7, y: 2, opacity: 0.045)
    }

    private var voicePlaybackCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(VoicePlaybackMode.allCases.enumerated()), id: \.element.id) { index, mode in
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

                if index < VoicePlaybackMode.allCases.count - 1 {
                    Rectangle()
                        .fill(AppTheme.divider)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
            }
        }
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .softShadow(radius: 7, y: 2, opacity: 0.045)
    }

    private var appearanceCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(AppearanceMode.allCases.enumerated()), id: \.element.id) { index, mode in
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

                if index < AppearanceMode.allCases.count - 1 {
                    Rectangle()
                        .fill(AppTheme.divider)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
            }
        }
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .softShadow(radius: 7, y: 2, opacity: 0.045)
    }

    private var preferenceCard: some View {
        VStack(spacing: 0) {
            ToggleRow(
                title: String(localized: "翻译后自动朗读译文"),
                subtitle: String(localized: "完成翻译后自动播放语音"),
                isOn: $settings.autoSpeaksTranslation
            )
            .accessibilityIdentifier("settings.autoSpeakToggle")
        }
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .softShadow(radius: 7, y: 2, opacity: 0.045)
    }

    private var footer: some View {
        Text("译境 · 版本 1.0")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AppTheme.faint)
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
    }

    private func select(_ engine: TranslationEngine) {
        guard engine.isAvailable, settings.translationEngine != engine else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        settings.translationEngine = engine
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

    private func accessibilityValue(for engine: TranslationEngine) -> String {
        guard engine.isAvailable else { return String(localized: "即将推出") }
        return settings.translationEngine == engine ? String(localized: "已选择") : ""
    }
}

private struct EngineRow: View {
    let engine: TranslationEngine
    let isSelected: Bool

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
            } else if isSelected {
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
