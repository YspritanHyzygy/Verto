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

struct AppShell: View {
    @State private var selectedMode: AppMode
    @State private var settings: AppSettings
    @State private var session: TranslationSession
    @State private var voiceController: VoiceConversationController
    @State private var appleTranslationProvider: AppleTranslationProvider
    @State private var sheetDestination: SheetDestination?
    private let usesCannedTranslation: Bool

    init() {
        let configuration = UITestLaunchConfiguration.current
        let settings = AppSettings()
        usesCannedTranslation = configuration.useCannedTranslation
        _selectedMode = State(initialValue: configuration.mode)
        _sheetDestination = State(initialValue: configuration.sheet)
        _settings = State(initialValue: settings)
        _session = State(initialValue: TranslationSession(
            settings: settings,
            service: configuration.useCannedTranslation ? CannedTranslationService() : nil
        ))

        let provider = AppleTranslationProvider()
        _appleTranslationProvider = State(initialValue: provider)
        let voiceTranslation: any TranslationService = configuration.useCannedTranslation
            ? CannedTranslationService()
            : VoiceTranslationRouter(apple: provider, fallback: GoogleTranslateService())
        var voiceTiming = VoiceConversationController.Timing()
        let transcriptionFactory: @MainActor () async -> any VoiceTranscriptionService
        var voiceSynthesizer: (any SpeechSynthesizing)?
#if DEBUG
        if configuration.useCannedSpeech {
            transcriptionFactory = { CannedSpeechTranscriptionService() }
            // 脚本化语音无停顿间隙，UI 测试用更短的端点窗口；不播真实 TTS。
            voiceTiming.endpointVolatileStability = 0.3
            voiceTiming.endpointSilenceDuration = 0
            voiceSynthesizer = SilentSpeechSynthesizer()
        } else {
            transcriptionFactory = { await SpeechEngineFactory.makeService() }
        }
#else
        transcriptionFactory = { await SpeechEngineFactory.makeService() }
#endif
        _voiceController = State(initialValue: VoiceConversationController(
            settings: settings,
            transcriptionFactory: transcriptionFactory,
            translationService: voiceTranslation,
            synthesizer: voiceSynthesizer,
            timing: voiceTiming
        ))
    }

    var body: some View {
        TabView(selection: $selectedMode) {
            TextTranslateView(
                session: session,
                settings: settings,
                onSwap: swapLanguages,
                onPickSource: { sheetDestination = .language(.source) },
                onPickTarget: { sheetDestination = .language(.target) },
                onHistory: { sheetDestination = .history },
                onSettings: { sheetDestination = .settings }
            )
            .tabItem {
                Label(AppMode.text.title, systemImage: AppMode.text.systemImage)
            }
            .tag(AppMode.text)

            VoiceConversationView(
                controller: voiceController,
                settings: settings,
                sourceLanguage: session.targetLanguage,
                targetLanguage: session.sourceLanguage,
                onPickSource: { sheetDestination = .language(.target) },
                onPickTarget: { sheetDestination = .language(.source) }
            )
            .tabItem {
                Label(AppMode.voice.title, systemImage: AppMode.voice.systemImage)
            }
            .tag(AppMode.voice)

            CameraTranslateView(
                sourceLanguage: session.sourceLanguage,
                targetLanguage: session.targetLanguage,
                onPickLanguage: { sheetDestination = .language(.target) }
            )
            .tabItem {
                Label(AppMode.camera.title, systemImage: AppMode.camera.systemImage)
            }
            .tag(AppMode.camera)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.paper.ignoresSafeArea())
        // iOS 18–25 的系统翻译宿主：常驻根部、跨 tab 不销毁（stale-session fatalError 防线）。
        .background(alignment: .bottomLeading) {
            if #available(iOS 18.0, *) {
                AppleTranslationHostView(provider: appleTranslationProvider)
            }
        }
        .tint(AppTheme.terracotta)
        .preferredColorScheme(settings.appearanceMode.colorScheme)
        .onChange(of: selectedMode) { previousMode, newMode in
            if previousMode == .text, newMode != .text {
                dismissKeyboard()
            }
        }
        .sensoryFeedback(.selection, trigger: selectedMode)
        .sheet(item: $sheetDestination) { destination in
            // sheet 是独立 presentation，不总是继承根部的 preferredColorScheme（同 tint 的怪癖），显式再套一层。
            sheetView(for: destination)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
        }
        .onChange(of: session.sourceLanguage) { _, newValue in
            settings.lastSourceLanguageCode = newValue.code
        }
        .onChange(of: session.targetLanguage) { _, newValue in
            settings.lastTargetLanguageCode = newValue.code
        }
#if DEBUG
        // UI 测试的固定演示译文模式必须一眼可辨，避免误当成真实翻译。
        .overlay(alignment: .top) {
            if usesCannedTranslation {
                Text("演示译文模式 · 未连接翻译服务")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.72), in: Capsule())
                    .padding(.top, 2)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("canned-translation-badge")
            }
        }
#endif
    }

    @ViewBuilder
    private func sheetView(for destination: SheetDestination) -> some View {
        switch destination {
        case .language(let role):
            LanguagePickerView(
                role: role,
                sourceSelection: languageBinding(for: .source),
                targetSelection: languageBinding(for: .target)
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(30)
        case .history:
            HistoryView(session: session) { item in
                session.load(item)
                selectedMode = .text
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(30)
        case .settings:
            SettingsView(settings: settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(30)
        }
    }

    private func languageBinding(for role: LanguageSelectionRole) -> Binding<Language> {
        Binding {
            role == .source ? session.sourceLanguage : session.targetLanguage
        } set: { newValue in
            session.select(newValue, for: role)
        }
    }

    private func swapLanguages() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        session.swapLanguages()
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

#Preview {
    AppShell()
}

private struct UITestLaunchConfiguration {
    let mode: AppMode
    let sheet: SheetDestination?
    let useCannedTranslation: Bool
    let useCannedSpeech: Bool

    static var current: UITestLaunchConfiguration {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let mode = value(after: "--uitest-mode", in: arguments)
            .flatMap(AppMode.init(rawValue:)) ?? .text
        let sheetValue = value(after: "--uitest-sheet", in: arguments)
        let sheet: SheetDestination?
        switch sheetValue {
        case "history": sheet = .history
        case "language-source": sheet = .language(.source)
        case "language-target": sheet = .language(.target)
        case "settings": sheet = .settings
        default: sheet = nil
        }
        return UITestLaunchConfiguration(
            mode: mode,
            sheet: sheet,
            useCannedTranslation: arguments.contains("--uitest-canned-translation"),
            useCannedSpeech: arguments.contains("--uitest-canned-speech")
        )
#else
        return UITestLaunchConfiguration(
            mode: .text,
            sheet: nil,
            useCannedTranslation: false,
            useCannedSpeech: false
        )
#endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
