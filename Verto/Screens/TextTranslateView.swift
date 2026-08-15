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
        .toast($toastText, identifier: "translation-toast")
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
        let surface = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return surface
            .fill(AppTheme.card)
            .overlay {
                surface
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
            || ProcessInfo.processInfo.arguments.contains("--uitest-reduce-motion")
#else
        accessibilityReduceMotion
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

    /// 自动消失由 .toast 修饰器负责，这里只管上屏。
    private func showToast(_ text: String) {
        withAnimation { toastText = text }
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

private enum TextEntryMotionTrace {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "Verto",
        category: "TextEntryMotion"
    )
}

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
