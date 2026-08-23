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
    @State private var photoController: PhotoTranslationController
    /// 高精度识别模型的安装状态。挂在 shell 上而不是相机页：下载会跨越标签页切换，
    /// 状态放在页面上会随页面销毁而丢失。
    @State private var modelCatalog: OCRModelCatalog?
    @State private var appleTranslationProvider: AppleTranslationProvider
    @State private var sheetDestination: SheetDestination?
    private let usesDemoData: Bool

    init() {
        let configuration = UITestLaunchConfiguration.current
        let settings = AppSettings()
        usesDemoData = configuration.useCannedTranslation || configuration.useCannedCamera
        _selectedMode = State(initialValue: configuration.mode)
        _sheetDestination = State(initialValue: configuration.sheet)
        _settings = State(initialValue: settings)
        _session = State(initialValue: TranslationSession(
            settings: settings,
            service: configuration.useCannedTranslation ? CannedTranslationService() : nil
        ))

        let provider = AppleTranslationProvider.shared
        _appleTranslationProvider = State(initialValue: provider)
        // 语音页仍是「苹果优先、失败回退」——那里选苹果是为了 350ms partial 重译的
        // 低延迟，走网络每条都要一个来回。回退项换成与文字/相机页同一个解析结果，
        // 否则它还指着已经被拦截的免费接口，整条回退链是死的。
        let voiceTranslation: any TranslationService = configuration.useCannedTranslation
            ? CannedTranslationService()
            : VoiceTranslationRouter(apple: provider, fallback: settings.translationEngine.makeService())
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

        let captureSource: any PhotoCaptureSource
        let recognizer: any TextRecognitionService
        // 罐头相机路径下不接 catalog：那条路一行真实模型代码都不碰，
        // 接进去只会让 UI 测试莫名其妙地去下载 13MB。
        var catalog: OCRModelCatalog?
#if DEBUG
        if configuration.useCannedCamera {
            // 模拟器无摄像头、UI 测试也开不了系统相册选择器：整条采集+识别链走合成实现，
            // 快门 → 叠加译文的全流程因此能在模拟器上真跑。
            captureSource = CannedPhotoCaptureSource()
            recognizer = CannedTextRecognitionService()
        } else {
            captureSource = CameraCaptureSource()
            recognizer = VisionTextRecognitionService()
            catalog = OCRModelCatalog(installer: OCRModelPackInstaller(), settings: settings)
        }
#else
        captureSource = CameraCaptureSource()
        recognizer = VisionTextRecognitionService()
        catalog = OCRModelCatalog(installer: OCRModelPackInstaller(), settings: settings)
#endif
        _modelCatalog = State(initialValue: catalog)
        _photoController = State(initialValue: PhotoTranslationController(
            settings: settings,
            captureSource: captureSource,
            recognizer: recognizer,
            modelCatalog: catalog,
            translationService: configuration.useCannedTranslation ? CannedTranslationService() : nil,
            synthesizer: voiceSynthesizer
        ))
    }

    var body: some View {
        TabView(selection: Binding(
            get: { selectedMode },
            set: selectMode
        )) {
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
                controller: photoController,
                session: session,
                settings: settings,
                onSwapLanguages: swapLanguages,
                ocrModelCatalog: modelCatalog
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
        // UI 测试的固定演示数据必须一眼可辨，避免误当成真实翻译/真实识别。
        .overlay(alignment: .top) {
            if usesDemoData {
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
            SettingsView(settings: settings, ocrModelCatalog: modelCatalog)
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

    private func selectMode(_ newMode: AppMode) {
        // 系统会把“再次点当前标签”转成其内容 ScrollView 的回顶部。结果页的
        // ScrollView 是照片画布，这个默认行为会把构图硬拽走；相机标签重选在
        // 产品语义上就是退出结果并重拍，所以在选择绑定这里直接拦截。
        if newMode == .camera, selectedMode == .camera, photoController.image != nil {
            photoController.reset()
            return
        }
        selectedMode = newMode
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
    let useCannedCamera: Bool

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
            useCannedSpeech: arguments.contains("--uitest-canned-speech"),
            useCannedCamera: arguments.contains("--uitest-canned-camera")
        )
#else
        return UITestLaunchConfiguration(
            mode: .text,
            sheet: nil,
            useCannedTranslation: false,
            useCannedSpeech: false,
            useCannedCamera: false
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
