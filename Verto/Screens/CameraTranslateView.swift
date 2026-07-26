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
import PhotosUI
import UIKit

struct CameraTranslateView: View {
    let sourceLanguage: Language
    let targetLanguage: Language
    let onPickLanguage: () -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var recognitionState: RecognitionState = .recognized
    @State private var recognitionRequest = 0
    @State private var isFlashOn = true
    @State private var isExposureLocked = false

    var body: some View {
        ZStack {
            cameraBackdrop
            menuSurface
            VStack(spacing: 0) {
                topBar
                Spacer()
                recognitionStack
                Spacer()
                captureControls
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .foregroundStyle(.white)
        .task(id: selectedPhoto) {
            await loadSelectedPhoto()
        }
        .task(id: recognitionRequest) {
            await completeRecognition(request: recognitionRequest)
        }
    }

    private var cameraBackdrop: some View {
        ZStack {
            if let selectedImage {
                Image(uiImage: selectedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                LinearGradient(
                    colors: [Color(hex: 0x6B5847), Color(hex: 0x4A3E32), Color(hex: 0x2E261E)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            if selectedImage != nil {
                LinearGradient(
                    colors: [.black.opacity(0.14), .black.opacity(0.4)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            RadialGradient(
                colors: [.white.opacity(0.14), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.24), value: selectedImage != nil)
    }

    private var menuSurface: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0xF3ECDD), Color(hex: 0xE4D8C2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(maxWidth: .infinity, maxHeight: 540)
            .padding(.horizontal, 36)
            .rotationEffect(.degrees(-1.5))
            .shadow(color: .black.opacity(0.42), radius: 34, x: 0, y: 24)
            .offset(y: 22)
    }

    private var topBar: some View {
        HStack {
            Button(action: onPickLanguage) {
                HStack(spacing: 8) {
                    Text(sourceLanguage.nativeName)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .bold))
                    Text(targetLanguage.nativeName)
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
            .accessibilityValue("\(sourceLanguage.nativeName)到\(targetLanguage.nativeName)")
            .accessibilityIdentifier("camera.languagePicker")

            Spacer()

            Button {
                isExposureLocked.toggle()
            } label: {
                Image(systemName: isExposureLocked ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isExposureLocked ? Color.yellow : Color.white)
                    .frame(width: 42, height: 42)
                    .liquidGlass(in: Circle()) { content in
                        content
                            .background(.black.opacity(isExposureLocked ? 0.42 : 0.28), in: Circle())
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("曝光锁定")
            .accessibilityValue(isExposureLocked ? "已锁定" : "自动")
            .accessibilityHint("轻点切换自动曝光和曝光锁定")
            .accessibilityIdentifier("camera.exposureButton")
        }
        .liquidGlassContainer()
    }

    private var recognitionStack: some View {
        VStack(spacing: 14) {
            switch recognitionState {
            case .ready:
                VStack(spacing: 10) {
                    Image(systemName: selectedImage == nil ? "viewfinder" : "photo.fill")
                        .font(.system(size: 25, weight: .medium))
                    Text(selectedImage == nil ? "对准菜单并轻点快门" : "图片已就绪，轻点快门识别")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("camera.recognitionReady")

            case .recognizing:
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.15)
                    Text("正在识别菜单…")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在识别菜单")
                .accessibilityIdentifier("camera.recognitionLoading")

            case .recognized:
                Text("已识别 · 菜单")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("camera.recognitionTitle")

                ForEach(MenuTranslation.samples) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.source)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.faint)
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.result)
                                .font(.system(size: 19, weight: .regular, design: .serif))
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                            Spacer()
                            Text(item.price)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AppTheme.terracotta)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 10)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.22), value: recognitionState)
    }

    private var captureControls: some View {
        HStack {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Group {
                    if let selectedImage {
                        Image(uiImage: selectedImage)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: [Color(hex: 0xC9B89A), Color(hex: 0x8A7960)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.5), lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("从照片图库选择菜单照片")
            .accessibilityValue(selectedImage == nil ? "未选择" : "已选择")
            .accessibilityIdentifier("camera.galleryPicker")

            Spacer()

            Button(action: startRecognition) {
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 74, height: 74)
                    .overlay {
                        if recognitionState == .recognizing {
                            ProgressView()
                                // 快门盘是固定白色的相机件，转圈也固定深色，不随 ink 自适应。
                                .tint(Color(hex: 0x1C1A17))
                                .frame(width: 58, height: 58)
                                .background(.white, in: Circle())
                        } else {
                            Circle()
                                .fill(.white)
                                .frame(width: 58, height: 58)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(recognitionState == .recognizing)
            .accessibilityLabel("拍摄并识别菜单")
            .accessibilityHint("轻点后识别菜单文字并显示翻译")
            .accessibilityIdentifier("camera.shutterButton")

            Spacer()

            Button {
                isFlashOn.toggle()
            } label: {
                Image(systemName: isFlashOn ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(isFlashOn ? Color.yellow : Color.white)
                    .frame(width: 46, height: 46)
                    .liquidGlass(in: Circle()) { content in
                        content
                            .background(.white.opacity(isFlashOn ? 0.24 : 0.16), in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("闪光灯")
            // 不用裸「关闭」：与关闭按钮的「关闭」（Close）同 key 异义，目录里无法各翻各的。
            .accessibilityValue(isFlashOn ? "已开启" : "已关闭")
            .accessibilityHint("轻点切换闪光灯")
            .accessibilityIdentifier("camera.flashButton")
        }
    }

    private func startRecognition() {
        recognitionState = .recognizing
        recognitionRequest += 1
    }

    @MainActor
    private func completeRecognition(request: Int) async {
        guard request > 0 else { return }

        do {
            try await Task.sleep(nanoseconds: 850_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled, request == recognitionRequest else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            recognitionState = .recognized
        }
    }

    @MainActor
    private func loadSelectedPhoto() async {
        guard let selectedPhoto else { return }

        guard let data = try? await selectedPhoto.loadTransferable(type: Data.self),
              !Task.isCancelled,
              let image = UIImage(data: data) else {
            return
        }

        recognitionRequest = 0
        withAnimation(.easeInOut(duration: 0.24)) {
            selectedImage = image
            recognitionState = .ready
        }
    }
}

private enum RecognitionState: Equatable {
    case ready
    case recognizing
    case recognized
}

#Preview {
    CameraTranslateView(
        sourceLanguage: .chinese,
        targetLanguage: .english,
        onPickLanguage: {}
    )
}
