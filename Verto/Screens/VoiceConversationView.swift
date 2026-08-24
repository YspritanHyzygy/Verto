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

struct VoiceConversationView: View {
    let controller: VoiceConversationController
    let settings: AppSettings
    let sourceLanguage: Language
    let targetLanguage: Language
    let onPickSource: () -> Void
    let onPickTarget: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            conversationList
        }
        // dock 悬浮在滚动内容之上：气泡从按钮后方经毛玻璃与纸色渐隐淡出，
        // 而不是被一条硬边界截断。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            listeningDock
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.paper.ignoresSafeArea())
        .onAppear {
            controller.setLanguages(source: sourceLanguage, target: targetLanguage)
        }
        .onChange(of: "\(sourceLanguage.code)>\(targetLanguage.code)") {
            controller.setLanguages(source: sourceLanguage, target: targetLanguage)
        }
        .onChange(of: scenePhase) { _, newPhase in
            controller.handleScenePhase(newPhase)
        }
        .onDisappear {
            controller.tearDown()
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("对话翻译")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppTheme.ink)

            LanguagePairPill(
                source: controller.voiceSource,
                target: controller.voiceTarget,
                onSourceTap: onPickSource,
                onTargetTap: onPickTarget
            )
            .accessibilityIdentifier("conversation-language-pair")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.divider)
                .frame(height: 1)
        }
        // 朗读模式的页内直达入口；完整设置仍在文字页右上角的设置页里。
        .overlay(alignment: .topTrailing) {
            playbackModeMenu
                .padding(.top, 14)
                .padding(.trailing, 18)
        }
    }

    private var playbackModeMenu: some View {
        Menu {
            ForEach(VoicePlaybackMode.allCases) { mode in
                Button {
                    settings.voicePlaybackMode = mode
                } label: {
                    if settings.voicePlaybackMode == mode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: playbackModeIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 38, height: 38)
                .liquidGlass(in: Circle()) { content in
                    content
                        .background(AppTheme.card, in: Circle())
                        .softShadow(radius: 5, y: 1, opacity: 0.06)
                }
        }
        .accessibilityLabel("译文朗读方式：\(settings.voicePlaybackMode.displayName)")
        .accessibilityIdentifier("conversation-playback-menu")
    }

    private var playbackModeIcon: String {
        switch settings.voicePlaybackMode {
        case .textOnly: "speaker.slash"
        case .speakAfterTranslation: "speaker.wave.2"
        case .speakOnlyWithHeadphones: "headphones"
        }
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    // 空态提示只在待机时出现——聆听中还提示「轻点开始」会自相矛盾。
                    if controller.turns.isEmpty && controller.live == nil && controller.phase == .idle {
                        emptyHint
                    }
                    ForEach(controller.turns) { turn in
                        ConversationBubble(
                            turn: turn,
                            onSpeak: { controller.speak(turn) },
                            onRetryTranslation: { controller.retryTranslation(for: turn.id) }
                        )
                        .id(turn.id)
                    }
                    if let live = controller.live {
                        LiveConversationBubble(
                            live: live,
                            reduceMotion: reduceMotion
                        )
                        .id("live-utterance")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 20)
            }
            .onChange(of: controller.turns.count) {
                guard let lastID = controller.turns.last?.id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            // 权威翻译异步填充/失败重试会把最后一条气泡撑高：跟滚到底。
            .onChange(of: lastTurnScrollFingerprint) {
                guard controller.live == nil, let lastID = controller.turns.last?.id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            // volatile 高频更新：贴底跟随但不加动画，避免逐字抖动。
            .onChange(of: controller.live?.original) {
                guard controller.live != nil else { return }
                proxy.scrollTo("live-utterance", anchor: .bottom)
            }
        }
    }

    /// 最后一条气泡里影响高度的所有字段——译文填充、翻译中/失败态变化都要跟滚。
    private var lastTurnScrollFingerprint: String {
        guard let last = controller.turns.last else { return "" }
        return "\(last.id)|\(last.translation)|\(last.isTranslationPending)|\(last.translationFailed)"
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.faint)
            Text("轻点开始双语对话")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.faint)
        }
        .padding(.top, 140)
        .accessibilityIdentifier("conversation-empty-hint")
    }

    private var listeningDock: some View {
        VStack(spacing: 14) {
            Text(controller.statusText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(controller.isListeningActive ? AppTheme.terracotta : AppTheme.muted)
                .contentTransition(.numericText())
                .accessibilityIdentifier("conversation-listening-status")

            if controller.isPermissionFailure {
                Button("前往设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.terracotta)
                .accessibilityIdentifier("conversation-open-settings")
            }

            HStack(spacing: 24) {
                languageCircle(
                    controller.voiceSource.code == "en" ? "EN" : String(controller.voiceSource.nativeName.prefix(1)),
                    speaker: .source,
                    label: String(localized: "使用\(controller.voiceSource.nativeName)讲话")
                )

                Button(action: { controller.toggleListening() }) {
                    ZStack {
                        if controller.isListeningActive && !hasLiquidGlass {
                            Circle()
                                .fill(AppTheme.terracotta.opacity(0.16))
                                .frame(width: 100, height: 100)
                        }
                        // Maps-style composition: the tinted disc sits inset inside
                        // the glass circle so the glass reads as a rim ring, and
                        // disc + ring deform as one unit under the interactive
                        // drag. A static halo would be left behind by that drag,
                        // so the glass path drops it.
                        Group {
                            micButtonContent
                        }
                        .frame(width: 84, height: 84)
                        .background(
                            controller.isListeningActive ? AppTheme.terracotta : AppTheme.muted,
                            in: Circle().inset(by: hasLiquidGlass ? 7 : 0)
                        )
                        .liquidGlass(interactive: true, in: Circle()) { content in
                            content
                                .softShadow(radius: 18, y: 8, opacity: 0.24)
                        }
                    }
                    .frame(width: 100, height: 100)
                }
                .buttonStyle(.plain)
                .disabled(micDisabled)
                .accessibilityLabel(controller.isListeningActive ? "暂停聆听" : "开始聆听")
                .accessibilityHint(controller.isListeningActive ? "结束当前这句并暂停" : "开始聆听并实时翻译")
                .accessibilityIdentifier("conversation-microphone-button")

                languageCircle(
                    controller.voiceTarget.code == "zh-Hans" ? "中" : String(controller.voiceTarget.nativeName.prefix(2)),
                    speaker: .target,
                    label: String(localized: "使用\(controller.voiceTarget.nativeName)讲话")
                )
            }
            .liquidGlassContainer(spacing: 8)
        }
        .padding(.top, 18)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        // 悬浮 dock：毛玻璃 + 纸色，顶部用渐隐遮罩收边——
        // 滚动内容在按钮后方模糊淡出，无硬边界。
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                AppTheme.paper.opacity(0.55)
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.32)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private var micButtonContent: some View {
        switch controller.phase {
        case .preparing, .finalizing:
            ProgressView()
                .tint(.white)
                .controlSize(.large)
        case .listening:
            WaveBars(level: controller.audioLevel)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
        case .idle, .failed:
            Image(systemName: "mic")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var micDisabled: Bool {
        switch controller.phase {
        case .preparing, .finalizing:
            true
        case .idle, .listening, .speaking, .failed:
            false
        }
    }

    private var hasLiquidGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private func languageCircle(
        _ text: String,
        speaker: ConversationTurn.Speaker,
        label: String
    ) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            controller.switchSpeaker(to: speaker)
        } label: {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(controller.activeSpeaker == speaker ? AppTheme.terracotta : AppTheme.muted)
                .frame(width: 54, height: 54)
                .liquidGlass(interactive: false, in: Circle()) { content in
                    content
                        .background(AppTheme.card, in: Circle())
                        .softShadow(radius: 7, y: 2, opacity: 0.07)
                }
                .overlay {
                    Circle()
                        .stroke(
                            controller.activeSpeaker == speaker ? AppTheme.terracotta.opacity(0.35) : .clear,
                            lineWidth: 1.5
                        )
                }
        }
        .buttonStyle(.plain)
        .disabled(micDisabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(speaker == .source ? "conversation-source-speaker" : "conversation-target-speaker")
    }
}

private struct ConversationBubble: View {
    let turn: ConversationTurn
    var onSpeak: (() -> Void)? = nil
    var onRetryTranslation: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: turn.speaker == .source ? .leading : .trailing, spacing: 5) {
            Text(turn.language)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(turn.speaker == .source ? AppTheme.faint : AppTheme.bubbleAccentLabel)
                .padding(.horizontal, 4)

            HStack(alignment: .bottom, spacing: 8) {
                if turn.speaker == .target, onSpeak != nil {
                    speakButton
                }
                bubbleBody
                if turn.speaker == .source, onSpeak != nil {
                    speakButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: turn.speaker == .source ? .leading : .trailing)
    }

    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(turn.original)
                .font(.system(size: 16, weight: .regular))
                .lineSpacing(3)
                .foregroundStyle(turn.speaker == .source ? AppTheme.ink : .white)
            // 权威翻译异步填充：进行中沿用粗译降透明度，失败给重试。
            Text(turn.translation.isEmpty ? "…" : turn.translation)
                .font(.system(size: 15, weight: .regular))
                .lineSpacing(3)
                .foregroundStyle(turn.speaker == .source ? AppTheme.muted : .white.opacity(0.74))
                .opacity(turn.isTranslationPending ? 0.45 : 1)
            if turn.translationFailed {
                Button {
                    onRetryTranslation?()
                } label: {
                    Text("翻译失败 · 轻点重试")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(turn.speaker == .source ? AppTheme.alert : .white)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation-turn-retry")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 310, alignment: .leading)
        .background(
            turn.speaker == .source ? AppTheme.card : AppTheme.terracottaFill,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 20,
                bottomLeadingRadius: turn.speaker == .source ? 6 : 20,
                bottomTrailingRadius: turn.speaker == .source ? 20 : 6,
                topTrailingRadius: 20,
                style: .continuous
            )
        )
        .softShadow(radius: 8, y: 3, opacity: turn.speaker == .source ? 0.045 : 0.12)
    }

    private var speakButton: some View {
        Button {
            onSpeak?()
        } label: {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 28, height: 28)
                .background(AppTheme.card, in: Circle())
                .softShadow(radius: 5, y: 1, opacity: 0.06)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("朗读译文")
        .accessibilityIdentifier("conversation-bubble-speak")
    }
}

/// 进行中的一句话：volatile 阶段原文/译文低透明度显示，定稿后原位实色替换
/// （Apple Live Translation 的官方呈现范式，不用斜体避免文字跳动）。
private struct LiveConversationBubble: View {
    let live: VoiceConversationController.LiveUtterance
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: live.speaker == .source ? .leading : .trailing, spacing: 5) {
            Text(live.languageName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(live.speaker == .source ? AppTheme.faint : AppTheme.bubbleAccentLabel)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 7) {
                Text(live.original)
                    .font(.system(size: 16, weight: .regular))
                    .lineSpacing(3)
                    .foregroundStyle(live.speaker == .source ? AppTheme.ink : .white)
                    .opacity(live.isFinal ? 1 : 0.55)
                Text(live.translation.isEmpty ? "…" : live.translation)
                    .font(.system(size: 15, weight: .regular))
                    .lineSpacing(3)
                    .foregroundStyle(live.speaker == .source ? AppTheme.muted : .white.opacity(0.74))
                    .opacity(live.isFinal ? 1 : 0.45)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 310, alignment: .leading)
            .background(
                live.speaker == .source ? AppTheme.card : AppTheme.terracottaFill,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 20,
                    bottomLeadingRadius: live.speaker == .source ? 6 : 20,
                    bottomTrailingRadius: live.speaker == .source ? 20 : 6,
                    topTrailingRadius: 20,
                    style: .continuous
                )
            )
            .softShadow(radius: 8, y: 3, opacity: live.speaker == .source ? 0.045 : 0.12)
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: live.isFinal)
        }
        .frame(maxWidth: .infinity, alignment: live.speaker == .source ? .leading : .trailing)
        .accessibilityIdentifier("conversation-live-bubble")
    }
}

#Preview {
    let settings = AppSettings()
    let controller = VoiceConversationController(
        settings: settings,
        transcriptionFactory: {
#if DEBUG
            CannedSpeechTranscriptionService()
#else
            await SpeechEngineFactory.makeService()
#endif
        },
        translationService: CannedTranslationService()
    )
    return VoiceConversationView(
        controller: controller,
        settings: settings,
        sourceLanguage: .english,
        targetLanguage: .chinese,
        onPickSource: {},
        onPickTarget: {}
    )
}
