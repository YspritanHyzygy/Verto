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

import PhotosUI
import SwiftUI
import UIKit

struct CameraTranslateView: View {
    @Bindable var controller: PhotoTranslationController
    let session: TranslationSession
    let settings: AppSettings
    let onPickLanguage: () -> Void
    /// 高精度识别模型的安装状态。为 nil 表示这一路不启用（罐头相机路径）。
    var ocrModelCatalog: OCRModelCatalog?

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedBlock: BlockSelection?
    @State private var toastText: String?
    @State private var zoomAtGestureStart: CGFloat?

    private var hasResultImage: Bool { controller.image != nil }

    var body: some View {
        ZStack {
            backdrop
            if !hasResultImage, let previewLayer = controller.captureSource.previewLayer {
                cameraInteractionLayer(previewLayer: previewLayer)
            }
            VStack(spacing: 0) {
                topBar
                // 出结果后状态条挂在顶栏下方，不留在屏幕中间——中间正好压着照片上的译文块。
                resultStatusBar
                Spacer()
                viewfinderStatus
                Spacer()
                captureControls
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .foregroundStyle(.white)
        // 顶部让开取景工具条，别压在语言胶囊上。
        .toast($toastText, topPadding: 70, identifier: "camera.toast")
        .task {
            controller.setLanguages(source: session.sourceLanguage, target: session.targetLanguage)
            // 首次进相机页顺带拉高精度识别模型。放在 start() 之前发起：它是后台任务，
            // 不阻塞取景；没下完的这段时间照常用系统引擎识别，下完自动切过去。
            ocrModelCatalog?.autoInstallDefaultIfNeeded()
            await controller.start()
        }
        .onChange(of: "\(session.sourceLanguage.code)>\(session.targetLanguage.code)") {
            controller.setLanguages(source: session.sourceLanguage, target: session.targetLanguage)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 退后台必须停会话：系统会强制中断，留着只会在回前台时拿到一个死会话。
            if newPhase == .active {
                Task { await controller.start() }
            } else {
                controller.stop()
            }
        }
        .onDisappear { controller.stop() }
        .task(id: selectedPhoto) { await loadSelectedPhoto() }
        .sheet(item: $selectedBlock) { selection in
            // sheet 是独立 presentation，不继承根部的 preferredColorScheme。
            blockDetail(for: selection.id)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
        }
    }

    // MARK: - 背景

    @ViewBuilder
    private var backdrop: some View {
        ZStack {
            if let image = controller.image {
                TranslationOverlayView(
                    image: image,
                    blocks: controller.blocks,
                    onSelect: { selectedBlock = BlockSelection(id: $0.id) }
                )
            } else if let previewLayer = controller.captureSource.previewLayer {
                CameraPreviewView(previewLayer: previewLayer)
            } else {
                // 无取景能力（模拟器、权限被拒）：中性底，不画假取景器。
                AppTheme.cameraBackdrop
            }
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.24), value: hasResultImage)
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack {
            Button(action: onPickLanguage) {
                HStack(spacing: 8) {
                    Text(session.sourceLanguage.nativeName)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .bold))
                    Text(session.targetLanguage.nativeName)
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .liquidGlass(in: Capsule()) { content in
                    content
                        .background(.black.opacity(0.28), in: Capsule())
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择翻译语言")
            .accessibilityValue("\(session.sourceLanguage.nativeName)到\(session.targetLanguage.nativeName)")
            .accessibilityIdentifier("camera.languagePicker")

            Spacer()

            if hasResultImage {
                glassCircleButton(
                    systemName: "xmark",
                    label: String(localized: "重拍"),
                    hint: String(localized: "轻点丢弃这张照片并回到取景"),
                    identifier: "camera.retakeButton",
                    action: controller.reset
                )
            }
        }
        .liquidGlassContainer()
    }

    // MARK: - 取景交互

    private func cameraInteractionLayer(previewLayer: AVCaptureVideoPreviewLayer) -> some View {
        GeometryReader { _ in
            let source = controller.captureSource
            let isAdjusting = source.isAdjustingFocus || source.isAdjustingExposure
            let focusPoint = previewLayer.layerPointConverted(
                fromCaptureDevicePoint: source.focusPointOfInterest
            )

            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        let devicePoint = previewLayer.captureDevicePointConverted(
                            fromLayerPoint: value.location
                        )
                        controller.focusAndMeter(at: devicePoint)
                    }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if zoomAtGestureStart == nil {
                                zoomAtGestureStart = source.displayZoomFactor
                            }
                            guard let zoomAtGestureStart else { return }
                            controller.setDisplayZoomFactor(zoomAtGestureStart * value.magnification)
                        }
                        .onEnded { _ in zoomAtGestureStart = nil }
                )
                .overlay {
                    if isAdjusting {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 72, height: 72)
                            .position(focusPoint)
                            .shadow(color: .black.opacity(0.42), radius: 2, y: 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(String(localized: "相机取景"))
                .accessibilityValue(zoomAccessibilityValue)
                .accessibilityHint(String(localized: "上下轻扫调整变焦倍率"))
                .accessibilityIdentifier("camera.viewfinder")
                .accessibilityAdjustableAction { direction in
                    let step: CGFloat = 0.1
                    switch direction {
                    case .increment:
                        controller.setDisplayZoomFactor(source.displayZoomFactor + step)
                    case .decrement:
                        controller.setDisplayZoomFactor(source.displayZoomFactor - step)
                    @unknown default:
                        break
                    }
                }
        }
        .ignoresSafeArea()
    }

    private var zoomAccessibilityValue: String {
        let factor = Double(controller.captureSource.displayZoomFactor).formatted(
            .number.precision(.fractionLength(0...1))
        )
        return String(
            format: String(localized: "当前变焦：%@ 倍"),
            locale: .current,
            factor
        )
    }

    // MARK: - 状态区

    /// 结果态的窄状态条，紧贴顶栏。
    @ViewBuilder
    private var resultStatusBar: some View {
        if controller.phase == .translating || controller.phase == .done {
            Text(controller.phase == .done ? "已翻译 · 轻点任意文字查看原文" : "正在翻译…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.42), in: Capsule())
                .padding(.top, 10)
                .accessibilityIdentifier("camera.recognitionTitle")
        }
    }

    /// 取景态（无结果）的居中提示：此时屏幕中间没有内容可挡。
    @ViewBuilder
    private var viewfinderStatus: some View {
        switch controller.phase {
        case .translating, .done:
            EmptyView()

        case .idle, .ready:
            statusCapsule {
                VStack(spacing: 10) {
                    Image(systemName: controller.captureSource.canCapture ? "viewfinder" : "photo.on.rectangle")
                        .font(.system(size: 25, weight: .medium))
                    Text(controller.captureSource.canCapture
                         ? "对准文字并轻点快门"
                         : "此设备没有可用的相机，请从相册选择照片")
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("camera.recognitionReady")

        case .recognizing:
            statusCapsule {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.15)
                    Text("正在识别文字…")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在识别文字")
            .accessibilityIdentifier("camera.recognitionLoading")

        case .failed:
            statusCapsule {
                VStack(spacing: 12) {
                    Text(controller.failureMessage ?? String(localized: "文字识别出错，请重试"))
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.center)
                    if controller.isPermissionFailure {
                        Button("前往设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("camera.openSettings")
                    } else if controller.image != nil {
                        Button("重试", action: controller.retryRecognition)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .accessibilityIdentifier("camera.retryButton")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("camera.recognitionError")
        }
    }

    private func statusCapsule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)
    }

    // MARK: - 底部控制

    private var captureControls: some View {
        // PhotosPicker 的 label 闭包不是 MainActor 隔离的，controller 的状态要先在
        // 这里（隔离上下文）读出来再带进去。
        let thumbnail = controller.image
        return HStack {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Group {
                    if let image = thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.34))
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.5), lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("从相册选择照片")
            .accessibilityValue(thumbnail == nil ? "未选择" : "已选择")
            .accessibilityIdentifier("camera.galleryPicker")

            Spacer()

            Button(action: controller.capture) {
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 74, height: 74)
                    .overlay {
                        if controller.isBusy {
                            ProgressView()
                                .tint(AppTheme.shutterInk)
                                .frame(width: 58, height: 58)
                                .background(.white, in: Circle())
                        } else {
                            Circle()
                                .fill(.white)
                                .frame(width: 58, height: 58)
                        }
                    }
                    .opacity(controller.canCapture ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!controller.canCapture)
            .accessibilityLabel("拍摄并翻译")
            .accessibilityHint("轻点后识别画面里的文字并就地显示译文")
            .accessibilityIdentifier("camera.shutterButton")

            Spacer()

            Button {
                controller.isFlashOn.toggle()
            } label: {
                Image(systemName: controller.isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(controller.isFlashOn ? Color.yellow : Color.white)
                    .frame(width: 46, height: 46)
                    .liquidGlass(in: Circle()) { content in
                        content
                            .background(.white.opacity(controller.isFlashOn ? 0.24 : 0.16), in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .disabled(!controller.captureSource.isFlashAvailable)
            .opacity(controller.captureSource.isFlashAvailable ? 1 : 0.45)
            .accessibilityLabel("闪光灯")
            // 不用裸「关闭」：与关闭按钮的「关闭」（Close）同 key 异义，目录里无法各翻各的。
            .accessibilityValue(controller.isFlashOn ? "已开启" : "已关闭")
            .accessibilityHint("轻点切换闪光灯")
            .accessibilityIdentifier("camera.flashButton")
        }
    }

    private func glassCircleButton(
        systemName: String,
        label: String,
        hint: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .liquidGlass(in: Circle()) { content in
                    content
                        .background(.black.opacity(0.28), in: Circle())
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - 单块详情

    @ViewBuilder
    private func blockDetail(for id: UUID) -> some View {
        if let block = controller.blocks.first(where: { $0.id == id }) {
            PhotoBlockDetailView(
                block: block,
                onCopy: {
                    UIPasteboard.general.string = block.displayText
                    showToast(String(localized: "译文已复制"))
                },
                onSpeak: { controller.speak(block) },
                onSave: { saveToHistory(block) },
                onRetry: { controller.retryTranslation(for: block.id) },
                onClose: { selectedBlock = nil }
            )
        }
    }

    private func saveToHistory(_ block: PhotoTranslationController.TranslatedBlock) {
        guard !block.translation.isEmpty else { return }
        let languages = controller.historyLanguages
        session.save(
            source: block.source,
            result: block.translation,
            sourceLanguage: languages.source,
            targetLanguage: languages.target
        )
        showToast(String(localized: "已存入历史记录"))
    }

    // MARK: - 相册

    @MainActor
    private func loadSelectedPhoto() async {
        guard let selectedPhoto else { return }
        guard let data = try? await selectedPhoto.loadTransferable(type: Data.self),
              !Task.isCancelled,
              let image = UIImage(data: data) else {
            return
        }
        controller.use(image)
    }

    /// 自动消失由 .toast 修饰器负责，这里只管上屏。
    private func showToast(_ text: String) {
        withAnimation { toastText = text }
    }

    /// sheet 需要 Identifiable，而块本身会随译文到达而变——只带 id 进 sheet，
    /// 内容每次从 controller 现取，重试后的新译文能原地刷新。
    private struct BlockSelection: Identifiable {
        let id: UUID
    }
}

private struct PhotoBlockDetailView: View {
    let block: PhotoTranslationController.TranslatedBlock
    let onCopy: () -> Void
    let onSpeak: () -> Void
    let onSave: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: String(localized: "原文"))
                Spacer()
                SheetCloseButton(action: onClose)
                    .accessibilityIdentifier("camera.blockDetail.close")
            }
            .padding(.bottom, 8)

            Text(block.source)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AppTheme.secondaryInk)
                .textSelection(.enabled)
                .accessibilityIdentifier("camera.blockDetail.source")

            Divider()
                .overlay(AppTheme.divider)
                .padding(.vertical, 16)

            SectionLabel(text: String(localized: "译文"))
                .padding(.bottom, 8)

            if block.failed {
                VStack(alignment: .leading, spacing: 12) {
                    Text("翻译失败，请重试")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryInk)
                    Button(action: onRetry) {
                        Text("重试")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(AppTheme.terracottaFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("camera.blockDetail.retry")
                }
            } else if block.isPending {
                HStack(spacing: 10) {
                    ProgressView().tint(AppTheme.terracotta)
                    Text("正在翻译…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryInk)
                }
                .accessibilityIdentifier("camera.blockDetail.loading")
            } else {
                Text(block.translation)
                    .font(.system(size: 21, weight: .regular, design: .serif))
                    .foregroundStyle(AppTheme.resultInk)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("camera.blockDetail.translation")
            }

            Spacer(minLength: 20)

            HStack(spacing: 22) {
                actionButton(systemName: "doc.on.doc", label: String(localized: "复制译文"), identifier: "camera.blockDetail.copy", action: onCopy)
                actionButton(systemName: "speaker.wave.2", label: String(localized: "朗读译文"), identifier: "camera.blockDetail.speak", action: onSpeak)
                actionButton(systemName: "clock.arrow.circlepath", label: String(localized: "存入历史记录"), identifier: "camera.blockDetail.save", action: onSave)
                Spacer()
            }
            .disabled(block.isPending || block.failed)
            .opacity(block.isPending || block.failed ? 0.4 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.paper.ignoresSafeArea())
    }

    private func actionButton(
        systemName: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TextActionIcon(systemName: systemName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    let settings = AppSettings()
    return CameraTranslateView(
        controller: PhotoTranslationController(
            settings: settings,
            captureSource: CameraCaptureSource(),
            recognizer: VisionTextRecognitionService()
        ),
        session: TranslationSession(settings: settings),
        settings: settings,
        onPickLanguage: {}
    )
}
