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

import AVFoundation
import Combine
import GameController
import OSLog
import SwiftUI
import UIKit

struct TextTranslateView: View {
    @Bindable var session: TranslationSession
    let settings: AppSettings
    let onSwap: () -> Void
    let onPickSource: () -> Void
    let onPickTarget: () -> Void
    let onHistory: () -> Void
    let onSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @FocusState private var sourceIsFocused: Bool
    @State private var draft: TextTranslationDraft?
    @State private var keyboardOverlap: CGFloat = 0
    @State private var expansionIsPrimed = false
    @State private var pendingPrimeTask: Task<Void, Never>?
    @State private var isDictating = false
    @State private var pendingAutoSpeak = false
    @State private var presentedSheet: TextTranslateSheet?
    @State private var toastText: String?
    @State private var speechSynthesizer = AVSpeechSynthesizer()
    @State private var impactFeedback = UIImpactFeedbackGenerator(style: .light)
    @State private var pendingFocusTask: Task<Void, Never>?
    @State private var transitionGeneration = 0
    @State private var transitionSignpostState: OSSignpostIntervalState?
#if DEBUG
    @State private var motionProbeTransitionID = 0
#endif

    var body: some View {
        VStack(spacing: 0) {
            header
            languagePairBar

            // The tab bar's safe-area contribution is applied asynchronously by
            // the system (released long after the hide begins, re-inserted via
            // a content crossfade on show), and the keyboard's region animates
            // under its own transaction, re-running layout every frame it
            // moves. The editing height must not depend on either, or its
            // .frame(height:) is rewritten mid-flight and fights the expand
            // spring (degenerate intermediate layouts included). Both readers
            // sit behind the keyboard region — its height arrives once via
            // notification instead (keyboardOverlap) — and the inner reader
            // also ignores the container's bottom inset so the editing height
            // is stable from the first frame; the outer reader only feeds an
            // invisible scroll margin that keeps idle content clear of the
            // floating bar.
            GeometryReader { insetProxy in
                GeometryReader { expandedProxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            sourceCard
                                .frame(height: focusedSourceCardHeight(expandedIn: expandedProxy))
                                .zIndex(1)

                            // Always in the tree; visibility is an explicit,
                            // value-scoped opacity. Structural insert/remove
                            // transitions kept getting their exit copy frozen
                            // mid-fade by concurrent keyboard-notification
                            // transactions (third-party keyboards fire several
                            // frame changes in quick succession), stranding a
                            // half-faded ghost below the editing card. A
                            // resident view has no exit copy to freeze, and
                            // riding the real layout keeps it glued below the
                            // card through the collapse. The reveal stays
                            // staged: hidden while the card closes, fading in
                            // once it settles; hiding uses the quick fade
                            // under the expanding card's zIndex.
                            resultGroup
                                .opacity(isEditingSource ? 0 : 1)
                                .allowsHitTesting(!isEditingSource)
                                .accessibilityHidden(isEditingSource)
                                .animation(
                                    isEditingSource
                                        ? motionProfile.contentFade
                                        : motionProfile.resultReveal,
                                    value: isEditingSource
                                )
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                    }
                    .scrollDisabled(isEditingSource)
                    .contentMargins(
                        .bottom,
                        max(0, expandedProxy.size.height - insetProxy.size.height),
                        for: .scrollContent
                    )
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .background(AppTheme.paper.ignoresSafeArea())
        .overlay(alignment: .top) {
            if let toastText {
                Text(toastText)
                    .font(.system(size: 13, weight: .semibold))
                    // ink 胶囊在深色下变浅米色，字色要跟着反转（paper 深色下是近黑）。
                    .foregroundStyle(AppTheme.paper)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(AppTheme.ink.opacity(0.9), in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("translation-toast")
            }
        }
        .overlay(alignment: .topLeading) {
            motionProbeAccessibilityView
        }
        .sheet(item: $presentedSheet, onDismiss: restoreDraftFocusIfNeeded) { destination in
            // sheet 是独立 presentation，不可靠继承根部的 preferredColorScheme，显式再套一层。
            sheetView(for: destination)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
        }
        .onAppear {
            // Warm the haptic engine off the transition's critical path; a
            // cold first impactOccurred() can stall the main thread.
            impactFeedback.prepare()
        }
        .onDisappear {
            cancelPendingFocus()
            cancelPendingPrime()
            transitionGeneration &+= 1
            endTransitionSignpost(markStable: false)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification
            )
        ) { notification in
            updateKeyboardOverlap(from: notification)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )
        ) { _ in
            // willChangeFrame already reports the off-screen end frame on
            // hide; this is a belt-and-braces reset only.
            setKeyboardOverlap(0)
        }
        .onChange(of: session.phase) { _, newPhase in
            guard pendingAutoSpeak else { return }
            switch newPhase {
            case .idle:
                pendingAutoSpeak = false
                if !session.translatedText.isEmpty {
                    speakResult()
                }
            case .failed:
                pendingAutoSpeak = false
            case .loading:
                break
            }
        }
        .toolbar(isEditingSource ? .hidden : .visible, for: .tabBar)
    }

    private var header: some View {
        HStack {
            Text("翻译")
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(AppTheme.ink)

            Spacer()

            // Glass shapes render through the shared container and ignore
            // ancestor opacity, so the two states swap structurally; the
            // transitions reproduce the old opacity/scale crossfade curves.
            ZStack(alignment: .trailing) {
                if isEditingSource {
                    Button(action: finishEditingAndTranslate) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .liquidGlass(tint: AppTheme.terracotta, in: Circle()) { content in
                                content
                                    .background(AppTheme.terracotta, in: Circle())
                                    .softShadow(radius: 9, y: 4, opacity: 0.2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("完成并翻译")
                    .accessibilityHint("提交当前文字并返回翻译结果")
                    .accessibilityIdentifier("finish-source-editing-button")
                    .transition(motionProfile.finishButtonTransition)
                } else {
                    HStack(spacing: 10) {
                        IconCircleButton(systemName: "clock", action: onHistory)
                            .accessibilityLabel("历史记录")
                            .accessibilityIdentifier("history-button")
                        IconCircleButton(systemName: "slider.horizontal.3", action: onSettings)
                            .accessibilityLabel("设置")
                            .accessibilityIdentifier("settings-button")
                    }
                    .transition(.opacity.animation(motionProfile.headerFade))
                }
            }
            .liquidGlassContainer(spacing: 2)
            .frame(width: 102, height: 46, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private var languagePairBar: some View {
        LanguagePairBar(
            source: activeSourceLanguage,
            target: activeTargetLanguage,
            sourceDisplayName: isEditingSource ? nil : session.sourceDisplayName,
            // 编辑中的草稿没有检测结果可用，源语言为自动检测时无从交换。
            isSwapEnabled: isEditingSource ? !activeSourceLanguage.isAuto : session.isSwapEnabled,
            onSourceTap: { presentLanguagePicker(for: .source) },
            onTargetTap: { presentLanguagePicker(for: .target) },
            onSwap: swapActiveLanguages
        )
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(
                text: activeSourceLanguage.nativeName.uppercased(),
                color: isEditingSource ? AppTheme.secondaryInk : AppTheme.faint
            )

            ZStack(alignment: .topLeading) {
                if activeSourceText.isEmpty {
                    Text("输入需要翻译的文字")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(AppTheme.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                TextEditor(text: sourceTextBinding)
                    .font(.system(size: 25, weight: .regular))
                    .lineSpacing(7)
                    .foregroundStyle(AppTheme.ink)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .frame(minHeight: 94, maxHeight: .infinity)
                    .focused($sourceIsFocused)
                    .allowsHitTesting(isEditingSource)
                    .accessibilityLabel("原文")
                    .accessibilityHint("输入完成后，点按右上角对勾翻译")
                    .accessibilityIdentifier("source-text-editor")
                    .accessibilityHidden(!isEditingSource)

                if !isEditingSource {
                    Button(action: beginEditingIfNeeded) {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("原文")
                    .accessibilityValue(activeSourceText)
                    .accessibilityHint("点按以编辑原文")
                    .accessibilityIdentifier("source-text-editor")
                }
            }

            HStack {
                Text("\(activeCharacterCount) 字")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.faint)

                Spacer()

                Button(action: startDemoDictation) {
                    Image(systemName: isDictating ? "waveform" : "mic")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isDictating ? "正在听写" : "开始听写")
                .accessibilityIdentifier("dictation-button")

                Button(action: clearActiveSource) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空原文")
                .accessibilityIdentifier("clear-source-button")
            }
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(AppTheme.muted)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background {
            sourceCardSurface(strokeOpacity: isEditingSource ? 0.24 : 0)
        }
    }

    private func sourceCardSurface(strokeOpacity: Double) -> some View {
        TextEntrySurfaceShape(reportsMotionProbe: motionProbeIsEnabled)
            .fill(AppTheme.card)
            .overlay {
                TextEntrySurfaceShape(reportsMotionProbe: false)
                    .stroke(AppTheme.terracotta.opacity(strokeOpacity), lineWidth: 1.5)
            }
            .softShadow(radius: 8, y: 2, opacity: 0.045)
    }

    private var resultGroup: some View {
        VStack(spacing: 14) {
            resultCard

            if session.hasAlternatives {
                Button {
                    presentedSheet = .alternatives
                } label: {
                    Text("轻点结果可查看其他译法")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.faint)
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(AppTheme.terracotta)
                    .frame(width: 7, height: 7)
                SectionLabel(
                    text: session.targetLanguage.nativeName.uppercased(),
                    color: AppTheme.terracotta
                )
            }

            switch session.phase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(AppTheme.terracotta)
                    Text("正在翻译…")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .accessibilityIdentifier("translation-loading")
            case .failed(let error):
                VStack(alignment: .leading, spacing: 12) {
                    Text(error.errorDescription ?? String(localized: "翻译失败，请重试"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                    Button {
                        session.refreshTranslation()
                    } label: {
                        Text("重试")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(AppTheme.terracottaFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("translation-retry-button")
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("translation-error")
            case .idle:
                Button {
                    presentedSheet = .alternatives
                } label: {
                    // 占位与译文拆开：三元里混入 String 变量会把整个表达式推成
                    // Text(String) 原样渲染，占位字面量就静默不本地化了。
                    Group {
                        if session.translatedText.isEmpty {
                            Text("译文会显示在这里")
                        } else {
                            Text(verbatim: session.translatedText)
                        }
                    }
                    .font(.system(size: 25, weight: .regular, design: .serif))
                    .lineSpacing(5)
                    .foregroundStyle(session.translatedText.isEmpty ? AppTheme.faint : AppTheme.resultInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .disabled(!session.hasAlternatives)
                .accessibilityLabel("译文")
                .accessibilityValue(session.translatedText)
                .accessibilityIdentifier("translation-result")
            }

            HStack(spacing: 16) {
                resultAction(
                    systemName: "speaker.wave.2",
                    label: String(localized: "朗读译文"),
                    identifier: "speak-result-button",
                    action: speakResult
                )
                resultAction(
                    systemName: "doc.on.doc",
                    label: String(localized: "复制译文"),
                    identifier: "copy-result-button",
                    color: AppTheme.actionMuted,
                    action: copyResult
                )
                resultAction(
                    systemName: session.isCurrentFavorite ? "star.fill" : "star",
                    label: session.isCurrentFavorite ? String(localized: "取消收藏") : String(localized: "收藏译文"),
                    identifier: "favorite-result-button",
                    color: session.isCurrentFavorite ? AppTheme.terracotta : AppTheme.actionMuted
                ) {
                    session.toggleCurrentFavorite()
                    showToast(session.isCurrentFavorite ? String(localized: "已收藏") : String(localized: "已取消收藏"))
                }

                Spacer()

                ShareLink(item: session.translatedText) {
                    TextActionIcon(systemName: "square.and.arrow.up", color: AppTheme.actionMuted)
                        .frame(width: 36, height: 36)
                }
                .disabled(session.translatedText.isEmpty)
                .accessibilityLabel("分享译文")
                .accessibilityIdentifier("share-result-button")
            }
            .padding(.top, 14)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AppTheme.terracotta.opacity(0.14))
                    .frame(height: 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(AppTheme.terracottaSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var isEditingSource: Bool {
        draft != nil
    }

    private var activeSourceText: String {
        draft?.sourceText ?? session.sourceText
    }

    private var activeSourceLanguage: Language {
        draft?.sourceLanguage ?? session.sourceLanguage
    }

    private var activeTargetLanguage: Language {
        draft?.targetLanguage ?? session.targetLanguage
    }

    private var activeCharacterCount: Int {
        activeSourceText.filter { !$0.isWhitespace }.count
    }

    private var motionProfile: TextEntryMotionProfile {
        TextEntryMotionProfile(reducesMotion: shouldReduceMotion)
    }

    private var shouldReduceMotion: Bool {
#if DEBUG
        accessibilityReduceMotion
            || ProcessInfo.processInfo.arguments.contains("--ui-testing-reduce-motion")
#else
        accessibilityReduceMotion
#endif
    }

    private var motionProbeIsEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing-text-entry-motion-probe")
#else
        false
#endif
    }

    @ViewBuilder
    private var motionProbeAccessibilityView: some View {
#if DEBUG
        if motionProbeIsEnabled {
            TextEntryMotionProbeAccessibilityView(reducesMotion: shouldReduceMotion)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
#endif
    }

    private var sourceTextBinding: Binding<String> {
        Binding {
            activeSourceText
        } set: { newValue in
            guard draft != nil else { return }
            draft?.sourceText = newValue
        }
    }

    private func focusedSourceCardHeight(expandedIn proxy: GeometryProxy) -> CGFloat? {
        // Expansion waits for the keyboard's end frame (or the short
        // no-keyboard fallback) before the height spring starts, so the card
        // aims at its true final height in a single motion instead of
        // overshooting toward the full viewport and folding back.
        guard isEditingSource, expansionIsPrimed else { return nil }
        // The expanded viewport reaches the physical screen bottom (both the
        // container and keyboard regions are ignored), so the proxy is static
        // for the whole transition. Sit 16pt above the keyboard when one is
        // up (keyboardOverlap arrives once per keyboard move, animated), and
        // otherwise clear the window's bottom safe area (home indicator plus
        // any system reserve) — a window-level inset that is stable
        // regardless of the tab bar, which is the whole point.
        let bottomClearance = max(keyboardOverlap + 16, max(16, windowBottomInset))
        return max(260, proxy.size.height - 16 - bottomClearance)
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .lazy
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private var windowBottomInset: CGFloat {
        keyWindow?.safeAreaInsets.bottom ?? 0
    }

    private func updateKeyboardOverlap(from notification: Notification) {
        guard
            let window = keyWindow,
            let endFrameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                as? NSValue
        else { return }
        // The end frame arrives in screen coordinates before the keyboard's
        // animation starts; on hide it slides off-screen with its height
        // intact, so the overlap must come from minY, not the frame height.
        let endFrame = window.convert(endFrameValue.cgRectValue, from: window.screen.coordinateSpace)
        setKeyboardOverlap(max(0, window.bounds.maxY - endFrame.minY))
    }

    private func setKeyboardOverlap(_ overlap: CGFloat) {
        // Any keyboard frame decision arriving while the expansion is still
        // waiting doubles as the primer: overlap and expansion commit in one
        // transaction, so the spring launches straight at the final height.
        let primesExpansion = isEditingSource && !expansionIsPrimed
        guard overlap != keyboardOverlap || primesExpansion else { return }
        if primesExpansion {
            cancelPendingPrime()
        }
        let updates = {
            keyboardOverlap = overlap
            if primesExpansion {
                expansionIsPrimed = true
            }
        }
        if motionProfile.reducesMotion {
            withNoAnimation(updates)
        } else {
            // A velocity-preserving retarget of the same spring that drives
            // the card, so the height folds the keyboard in as one motion.
            withAnimation(motionProfile.expandAnimation, updates)
        }
    }

    private func scheduleExpansionPrimeFallback() {
        cancelPendingPrime()
        pendingPrimeTask = Task { @MainActor in
            // The keyboard's end frame is the preferred primer. With a
            // hardware keyboard attached no software keyboard is coming, so
            // expand to the full height after one beat. Without one, the
            // notification always arrives — but a cold keyboard process can
            // need several hundred ms, so wait it out rather than launching
            // toward the wrong (full) height and folding back.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            if GCKeyboard.coalesced == nil, !expansionIsPrimed {
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled else { return }
            }
            pendingPrimeTask = nil
            guard isEditingSource, !expansionIsPrimed else { return }
            if motionProfile.reducesMotion {
                withNoAnimation {
                    expansionIsPrimed = true
                }
            } else {
                withAnimation(motionProfile.expandAnimation) {
                    expansionIsPrimed = true
                }
            }
        }
    }

    private func cancelPendingPrime() {
        pendingPrimeTask?.cancel()
        pendingPrimeTask = nil
    }

    private func beginEditingIfNeeded() {
        guard draft == nil else {
            scheduleSourceFocus(afterNanoseconds: 0)
            return
        }

        transitionGeneration &+= 1
        let generation = transitionGeneration
        endTransitionSignpost(markStable: false)
        beginTransitionSignpost()
        TextEntryMotionTrace.signposter.emitEvent("TextEntryTapped")
        beginMotionProbe(direction: .entering)

        let initialDraft = session.makeTextDraft()

        if motionProfile.reducesMotion {
            withNoAnimation {
                draft = initialDraft
            }
            handleEnterCompletion(generation: generation)
        } else {
            withAnimation(
                motionProfile.expandAnimation,
                completionCriteria: .removed
            ) {
                draft = initialDraft
            } completion: {
                handleEnterCompletion(generation: generation)
            }
        }

        scheduleSourceFocus(afterNanoseconds: 0)
        scheduleExpansionPrimeFallback()
    }

    private func handleEnterCompletion(generation: Int) {
        guard generation == transitionGeneration else { return }
        completeMotionProbe(direction: .entering)
        endTransitionSignpost(markStable: true)
    }

    private func finishEditingAndTranslate() {
        guard let completedDraft = draft else { return }
        // 翻译是异步的，先记下意图，等 phase 回到 idle 再朗读。
        pendingAutoSpeak = settings.autoSpeaksTranslation
            && !completedDraft.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancelPendingFocus()
        cancelPendingPrime()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        endTransitionSignpost(markStable: false)
        beginTransitionSignpost()
        beginMotionProbe(direction: .exiting)
        // Dropping focus in the same frame as the collapse commit makes the
        // text view re-lay its content against the mid-commit geometry — the
        // text renders one frame displaced and gets dragged back by the
        // spring. Resign on the next runloop turn instead, once the collapse
        // transaction has established its animation state.
        Task { @MainActor in
            sourceIsFocused = false
        }

        if motionProfile.reducesMotion {
            withNoAnimation {
                session.commitAndTranslate(completedDraft)
                draft = nil
                expansionIsPrimed = false
            }
            handleExitCompletion(generation: generation)
        } else {
            withAnimation(
                motionProfile.collapseAnimation,
                completionCriteria: .removed
            ) {
                session.commitAndTranslate(completedDraft)
                draft = nil
                expansionIsPrimed = false
            } completion: {
                handleExitCompletion(generation: generation)
            }
        }
        impactFeedback.impactOccurred()
        // 缓存命中时翻译同步完成，phase 不经过 loading，onChange 不会触发——当场朗读。
        if pendingAutoSpeak, session.phase == .idle, !session.translatedText.isEmpty {
            pendingAutoSpeak = false
            speakResult()
        }
    }

    private func handleExitCompletion(generation: Int) {
        guard generation == transitionGeneration else { return }
        completeMotionProbe(direction: .exiting)
        endTransitionSignpost(markStable: true)
    }

    private func clearActiveSource() {
        if draft != nil {
            draft?.sourceText = ""
            scheduleSourceFocus(afterNanoseconds: 0)
        } else {
            session.clearCurrent()
        }
    }

    private func presentLanguagePicker(for role: LanguageSelectionRole) {
        if isEditingSource {
            cancelPendingFocus()
            sourceIsFocused = false
            presentedSheet = .draftLanguage(role)
        } else if role == .source {
            onPickSource()
        } else {
            onPickTarget()
        }
    }

    private func swapActiveLanguages() {
        guard var currentDraft = draft else {
            onSwap()
            return
        }

        let previousSource = currentDraft.sourceLanguage
        currentDraft.sourceLanguage = currentDraft.targetLanguage
        currentDraft.targetLanguage = previousSource
        draft = currentDraft
        impactFeedback.impactOccurred()
    }

    private func draftLanguageBinding(for role: LanguageSelectionRole) -> Binding<Language> {
        Binding {
            guard let draft else {
                return role == .source ? session.sourceLanguage : session.targetLanguage
            }
            return role == .source ? draft.sourceLanguage : draft.targetLanguage
        } set: { newValue in
            guard var currentDraft = draft else { return }
            if role == .source {
                currentDraft.sourceLanguage = newValue
            } else {
                currentDraft.targetLanguage = newValue
            }
            draft = currentDraft
        }
    }

    @ViewBuilder
    private func sheetView(for destination: TextTranslateSheet) -> some View {
        switch destination {
        case .alternatives:
            AlternativeTranslationsView(session: session)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        case .draftLanguage(let role):
            LanguagePickerView(
                role: role,
                sourceSelection: draftLanguageBinding(for: .source),
                targetSelection: draftLanguageBinding(for: .target)
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(30)
        }
    }

    private func restoreDraftFocusIfNeeded() {
        guard draft != nil else { return }
        scheduleSourceFocus(afterNanoseconds: 0)
    }

    private func scheduleSourceFocus(afterNanoseconds delay: UInt64) {
        cancelPendingFocus()
        pendingFocusTask = Task { @MainActor in
            if delay == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(nanoseconds: delay)
            }

            guard !Task.isCancelled,
                  draft != nil,
                  presentedSheet == nil else { return }
            pendingFocusTask = nil
            TextEntryMotionTrace.signposter.emitEvent("TextEntryFocusRequested")
            sourceIsFocused = true
        }
    }

    private func cancelPendingFocus() {
        pendingFocusTask?.cancel()
        pendingFocusTask = nil
    }

    private func beginMotionProbe(direction: TextEntryMotionDirection) {
#if DEBUG
        motionProbeTransitionID &+= 1
        if motionProbeIsEnabled {
            TextEntryMotionProbe.shared.begin(
                id: motionProbeTransitionID,
                direction: direction,
                reducesMotion: shouldReduceMotion
            )
        }
#endif
    }

    private func completeMotionProbe(direction: TextEntryMotionDirection) {
#if DEBUG
        guard motionProbeIsEnabled else { return }
        let id = motionProbeTransitionID
        Task { @MainActor in
            // The keyboard notification retargets the card's height once,
            // shortly after the transition starts, which can fire the original
            // transaction's completion early. Give the retargeted spring time
            // to settle before freezing the track's expected end point;
            // geometry samples keep flowing until then.
            try? await Task.sleep(nanoseconds: 400_000_000)
            TextEntryMotionProbe.shared.complete(id: id, direction: direction)
        }
#endif
    }

    private func beginTransitionSignpost() {
        transitionSignpostState = TextEntryMotionTrace.signposter.beginInterval("TextEntryTransition")
    }

    private func endTransitionSignpost(markStable: Bool) {
        guard let transitionSignpostState else { return }
        if markStable {
            TextEntryMotionTrace.signposter.emitEvent("TextEntryStable")
        }
        TextEntryMotionTrace.signposter.endInterval("TextEntryTransition", transitionSignpostState)
        self.transitionSignpostState = nil
    }

    private func withNoAnimation(_ updates: () -> Void) {
        withTransaction(Transaction(animation: nil), updates)
    }

    private func resultAction(
        systemName: String,
        label: String,
        identifier: String,
        color: Color = AppTheme.terracotta.opacity(0.78),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TextActionIcon(systemName: systemName, color: color)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .disabled(session.translatedText.isEmpty)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func startDemoDictation() {
        guard !isDictating else { return }
        beginEditingIfNeeded()
        isDictating = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        showToast(String(localized: "正在听写…"))
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard draft != nil else {
                isDictating = false
                return
            }
            draft?.sourceText = activeSourceLanguage.code == "zh-Hans" ? "你好" : "Good morning"
            isDictating = false
        }
    }

    private func speakResult() {
        guard !session.translatedText.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: session.translatedText)
        utterance.voice = AVSpeechSynthesisVoice(language: session.targetLanguage.code)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(utterance)
        showToast(String(localized: "正在朗读"))
    }

    private func copyResult() {
        UIPasteboard.general.string = session.translatedText
        session.saveCurrent()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showToast(String(localized: "译文已复制"))
    }

    private func showToast(_ text: String) {
        withAnimation { toastText = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if toastText == text {
                withAnimation { toastText = nil }
            }
        }
    }
}

private struct TextEntryMotionProfile {
    let reducesMotion: Bool

    // One restrained spring drives the live card's layout; the keyboard and
    // tab bar animate concurrently under their own system transactions and the
    // spring retargets smoothly when they change the available height.
    var expandAnimation: Animation {
        .spring(duration: 0.45, bounce: 0.12)
    }

    var collapseAnimation: Animation {
        .smooth(duration: 0.32)
    }

    var contentFade: Animation {
        .easeOut(duration: reducesMotion ? 0.12 : 0.16)
    }

    // Timed against collapseAnimation (0.32s): the card has cleared the
    // result's area by ~0.13s, so the fade can start just behind that —
    // opacity is still low while the last of the travel finishes, and the
    // translation reads as surfacing the moment the card lands.
    var resultReveal: Animation {
        reducesMotion
            ? contentFade
            : .easeOut(duration: 0.18).delay(0.12)
    }

    var headerFade: Animation {
        .easeOut(duration: reducesMotion ? 0.12 : 0.15)
    }

    var finishButtonAnimation: Animation {
        reducesMotion
            ? .easeOut(duration: 0.12)
            : .spring(duration: 0.30, bounce: 0.22).delay(0.04)
    }

    var finishButtonTransition: AnyTransition {
        guard !reducesMotion else {
            return .opacity.animation(finishButtonAnimation)
        }
        return .opacity.combined(with: .scale(scale: 0.84))
            .animation(finishButtonAnimation)
    }
}

/// The live source card's surface. Shapes re-resolve their path every frame
/// of an animated resize (keeping the continuous corners undistorted), which
/// also makes this the one place that observes the card's true frame-by-frame
/// geometry — the DEBUG motion probe taps into that here.
private struct TextEntrySurfaceShape: Shape {
    let reportsMotionProbe: Bool

    func path(in rect: CGRect) -> Path {
#if DEBUG
        if reportsMotionProbe {
            TextEntryMotionProbe.shared.noteCardGeometry(
                bottomY: rect.maxY,
                isValid: rect.width > 1
            )
        }
#endif
        return RoundedRectangle(cornerRadius: 22, style: .continuous).path(in: rect)
    }
}

private enum TextEntryMotionDirection: String {
    case idle
    case entering = "enter"
    case exiting = "exit"
}

private enum TextEntryMotionTrace {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "Verto",
        category: "TextEntryMotion"
    )
}

#if DEBUG
private struct TextEntryMotionProbeAccessibilityView: UIViewRepresentable {
    let reducesMotion: Bool

    func makeUIView(context: Context) -> TextEntryMotionProbeAXView {
        let view = TextEntryMotionProbeAXView()
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "text-entry-motion-probe"
        view.accessibilityLabel = "文字键入动画探针"
        view.backgroundColor = .clear
        TextEntryMotionProbe.shared.setReducesMotion(reducesMotion)
        TextEntryMotionProbeAXRegistry.shared.attach(view)
        return view
    }

    func updateUIView(_ uiView: TextEntryMotionProbeAXView, context: Context) {
        TextEntryMotionProbe.shared.setReducesMotion(reducesMotion)
        TextEntryMotionProbeAXRegistry.shared.attach(uiView)
    }

    static func dismantleUIView(_ uiView: TextEntryMotionProbeAXView, coordinator: Void) {
        TextEntryMotionProbeAXRegistry.shared.detach(uiView)
    }
}

private final class TextEntryMotionProbeAXView: UIView {
    override var accessibilityValue: String? {
        get { TextEntryMotionProbe.shared.accessibilityValue }
        set {}
    }
}

@MainActor
private final class TextEntryMotionProbeAXRegistry {
    static let shared = TextEntryMotionProbeAXRegistry()
    private weak var view: UIView?

    func attach(_ view: UIView) {
        self.view = view
    }

    func detach(_ view: UIView) {
        if self.view === view {
            self.view = nil
        }
    }

    func postChange() {
        guard view != nil else { return }
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}

/// Records the live source card's animated bottom edge during entry/exit
/// transitions. Samples come straight from the card's real geometry, so a
/// passing track proves the on-screen layout actually moved through
/// intermediate frames instead of snapping.
private final class TextEntryMotionProbe: @unchecked Sendable {
    static let shared = TextEntryMotionProbe()

    private struct Sample {
        let bottomY: CGFloat
        let geometryIsValid: Bool
    }

    private struct Track {
        var id = 0
        var initialBottomY: CGFloat = 0
        var expectedBottomY: CGFloat?
        var samples: [Sample] = []
        var isComplete = false

        mutating func append(_ sample: Sample) {
            guard !isComplete, samples.count < 240 else { return }
            if let last = samples.last,
               abs(last.bottomY - sample.bottomY) < 0.5 {
                return
            }
            samples.append(sample)
        }

        func evaluation(for direction: TextEntryMotionDirection) -> Evaluation {
            guard let expectedBottomY else {
                return .empty
            }

            let validSamples = samples.filter {
                $0.geometryIsValid && $0.bottomY.isFinite
            }
            let signedDistance = direction == .entering
                ? expectedBottomY - initialBottomY
                : initialBottomY - expectedBottomY
            let distance = max(0, signedDistance)
            guard distance >= 24 else {
                return Evaluation(
                    sawStart: false,
                    sawMiddle: false,
                    sawEnd: false,
                    steps: 0,
                    geometryIsValid: false,
                    isMonotonic: false,
                    distance: distance,
                    passed: false
                )
            }

            let normalizedPositions = validSamples.map { sample -> CGFloat in
                let travelled = direction == .entering
                    ? sample.bottomY - initialBottomY
                    : initialBottomY - sample.bottomY
                return min(1, max(0, travelled / distance))
            }
            let sawStart = normalizedPositions.contains { $0 <= 0.12 }
            let sawMiddle = normalizedPositions.contains { $0 > 0.12 && $0 < 0.88 }
            let sawEnd = normalizedPositions.contains { $0 >= 0.88 }
            let steps = Set(normalizedPositions.map { Int(($0 * 20).rounded()) }).count
            let regressionTolerance = max(3, distance * 0.04)
            var extreme = initialBottomY
            var isMonotonic = true
            for sample in validSamples {
                if direction == .entering {
                    if sample.bottomY < extreme - regressionTolerance {
                        isMonotonic = false
                        break
                    }
                    extreme = max(extreme, sample.bottomY)
                } else {
                    if sample.bottomY > extreme + regressionTolerance {
                        isMonotonic = false
                        break
                    }
                    extreme = min(extreme, sample.bottomY)
                }
            }

            return Evaluation(
                sawStart: sawStart,
                sawMiddle: sawMiddle,
                sawEnd: sawEnd,
                steps: steps,
                geometryIsValid: !validSamples.isEmpty,
                isMonotonic: isMonotonic,
                distance: distance,
                passed: isComplete
                    && sawStart
                    && sawMiddle
                    && sawEnd
                    && steps >= 3
                    && isMonotonic
            )
        }
    }

    private struct Evaluation {
        let sawStart: Bool
        let sawMiddle: Bool
        let sawEnd: Bool
        let steps: Int
        let geometryIsValid: Bool
        let isMonotonic: Bool
        let distance: CGFloat
        let passed: Bool

        static let empty = Evaluation(
            sawStart: false,
            sawMiddle: false,
            sawEnd: false,
            steps: 0,
            geometryIsValid: false,
            isMonotonic: false,
            distance: 0,
            passed: false
        )
    }

    private let lock = NSLock()
    private let enabled = ProcessInfo.processInfo.arguments.contains(
        "--ui-testing-text-entry-motion-probe"
    )
    private var reducesMotion = false
    private var lastBottomY: CGFloat?
    private var activeDirection: TextEntryMotionDirection = .idle
    private var activeID = 0
    private var enterTrack = Track()
    private var exitTrack = Track()

    var accessibilityValue: String {
        lock.lock()
        defer { lock.unlock() }
        let enter = enterTrack.evaluation(for: .entering)
        let exit = exitTrack.evaluation(for: .exiting)
        return [
            "reduce=\(reducesMotion ? 1 : 0)",
            summary(name: "enter", track: enterTrack, evaluation: enter),
            summary(name: "exit", track: exitTrack, evaluation: exit)
        ].joined(separator: ";")
    }

    func setReducesMotion(_ reducesMotion: Bool) {
        guard enabled else { return }
        lock.lock()
        self.reducesMotion = reducesMotion
        lock.unlock()
    }

    func noteCardGeometry(bottomY: CGFloat, isValid: Bool) {
        guard enabled else { return }
        lock.lock()
        lastBottomY = bottomY
        if activeDirection != .idle {
            let sample = Sample(bottomY: bottomY, geometryIsValid: isValid)
            switch activeDirection {
            case .entering where enterTrack.id == activeID:
                enterTrack.append(sample)
            case .exiting where exitTrack.id == activeID:
                exitTrack.append(sample)
            default:
                break
            }
        }
        lock.unlock()
    }

    func begin(
        id: Int,
        direction: TextEntryMotionDirection,
        reducesMotion: Bool
    ) {
        guard enabled, direction != .idle else { return }
        lock.lock()
        self.reducesMotion = reducesMotion
        let initialBottomY = lastBottomY ?? 0
        switch direction {
        case .entering:
            enterTrack = Track(id: id, initialBottomY: initialBottomY)
        case .exiting:
            exitTrack = Track(id: id, initialBottomY: initialBottomY)
        case .idle:
            break
        }
        activeDirection = direction
        activeID = id
        lock.unlock()
        scheduleAccessibilityUpdate()
    }

    func complete(id: Int, direction: TextEntryMotionDirection) {
        guard enabled, direction != .idle else { return }
        lock.lock()
        let expectedBottomY = lastBottomY
        switch direction {
        case .entering where enterTrack.id == id:
            enterTrack.expectedBottomY = expectedBottomY
            enterTrack.isComplete = true
        case .exiting where exitTrack.id == id:
            exitTrack.expectedBottomY = expectedBottomY
            exitTrack.isComplete = true
        default:
            break
        }
        if activeID == id, activeDirection == direction {
            activeDirection = .idle
        }
        lock.unlock()
        scheduleAccessibilityUpdate()
    }

    private func summary(
        name: String,
        track: Track,
        evaluation: Evaluation
    ) -> String {
        let state = track.id == 0 ? "idle" : (track.isComplete ? "complete" : "running")
        return "\(name)-state=\(state)"
            + ";\(name)-id=\(track.id)"
            + ";\(name)-start=\(evaluation.sawStart ? 1 : 0)"
            + ";\(name)-mid=\(evaluation.sawMiddle ? 1 : 0)"
            + ";\(name)-end=\(evaluation.sawEnd ? 1 : 0)"
            + ";\(name)-steps=\(evaluation.steps)"
            + ";\(name)-geometry=\(evaluation.geometryIsValid ? 1 : 0)"
            + ";\(name)-monotonic=\(evaluation.isMonotonic ? 1 : 0)"
            + ";\(name)-delta=\(Int(evaluation.distance.rounded()))"
            + ";\(name)-pass=\(evaluation.passed ? 1 : 0)"
    }

    private func scheduleAccessibilityUpdate() {
        Task { @MainActor in
            TextEntryMotionProbeAXRegistry.shared.postChange()
        }
    }
}
#endif

private enum TextTranslateSheet: Identifiable {
    case alternatives
    case draftLanguage(LanguageSelectionRole)

    var id: String {
        switch self {
        case .alternatives:
            return "alternatives"
        case .draftLanguage(let role):
            return "draft-language-\(role.rawValue)"
        }
    }
}

private struct AlternativeTranslationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: TranslationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("其他译法")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                SheetCloseButton { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            List {
                ForEach(session.translationCandidates.indices, id: \.self) { index in
                    let alternative = session.translationCandidates[index]

                    Button {
                        session.translatedText = alternative
                        session.saveCurrent()
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(verbatim: "\(index + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(AppTheme.terracotta, in: Circle())
                            Text(alternative)
                                .font(.system(size: 17, design: .serif))
                                .foregroundStyle(AppTheme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("alternative-\(index + 1)")
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(AppTheme.paper.ignoresSafeArea())
    }
}

#Preview {
    TextTranslateView(
        session: TranslationSession(),
        settings: AppSettings(),
        onSwap: {},
        onPickSource: {},
        onPickTarget: {},
        onHistory: {},
        onSettings: {}
    )
}
