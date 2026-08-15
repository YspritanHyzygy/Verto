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
import ImageIO
import SwiftUI
import UIKit

enum CameraCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case unavailable
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "未获得相机权限，请在系统设置中开启")
        case .unavailable: String(localized: "此设备没有可用的相机，请从相册选择照片")
        case .captureFailed: String(localized: "拍照失败，请重试")
        }
    }
}

/// 取景与拍照。真实实现走 AVFoundation；UI 测试注入合成实现
/// （见 `CannedPhotoCaptureSource`），因此整条管线在模拟器上也能全流程跑通。
@MainActor
protocol PhotoCaptureSource: AnyObject {
    /// 能否产出照片。模拟器无摄像头、权限被拒时为 false，此时快门置灰、相册入口提到主位。
    var canCapture: Bool { get }
    var isFlashAvailable: Bool { get }
    /// 权限被拒（区别于设备本就没有相机）——只有这种情况给「前往设置」。
    var isPermissionDenied: Bool { get }
    /// 取景预览层；无取景能力的实现返回 nil。
    var previewLayer: AVCaptureVideoPreviewLayer? { get }
    /// 设备正在实际调整对焦/曝光。取景框只跟随这两个原始硬件状态，不靠计时器猜。
    var isAdjustingFocus: Bool { get }
    var isAdjustingExposure: Bool { get }
    /// AVCaptureDevice 坐标（左上为 0,0），供取景层把真实对焦点画回屏幕。
    var focusPointOfInterest: CGPoint { get }
    /// 与系统相机界面一致的展示倍率；iOS 18 起由设备提供换算系数。
    var displayZoomFactor: CGFloat { get }
    var minimumDisplayZoomFactor: CGFloat { get }
    var maximumDisplayZoomFactor: CGFloat { get }

    /// 请求权限并启动会话。可重复调用，已在运行时是空操作。
    func start() async
    func stop()
    func setFlashEnabled(_ enabled: Bool)
    func focusAndMeter(at devicePoint: CGPoint)
    func setDisplayZoomFactor(_ factor: CGFloat)
    func capturePhoto() async throws -> UIImage
}

@Observable
@MainActor
final class CameraCaptureSource: PhotoCaptureSource {
    private(set) var canCapture = false
    private(set) var isFlashAvailable = false
    private(set) var isPermissionDenied = false
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private(set) var isAdjustingFocus = false
    private(set) var isAdjustingExposure = false
    private(set) var focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
    private(set) var displayZoomFactor: CGFloat = 1
    private(set) var minimumDisplayZoomFactor: CGFloat = 1
    private(set) var maximumDisplayZoomFactor: CGFloat = 1

    @ObservationIgnored private let engine = CaptureEngine()
    @ObservationIgnored private var flashEnabled = false
    /// 拍照结果经 delegate 回调，而 AVCapturePhotoOutput 不持有 delegate——
    /// 不自己留一份，delegate 会在 await 期间被释放，回调永不到达。
    @ObservationIgnored private var pendingCaptures: [UUID: PhotoCaptureDelegate] = [:]

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                markUnavailable(permissionDenied: true)
                return
            }
        case .denied, .restricted:
            markUnavailable(permissionDenied: true)
            return
        @unknown default:
            markUnavailable(permissionDenied: true)
            return
        }
        isPermissionDenied = false

        engine.setStateHandler { [weak self] state in
            Task { @MainActor [weak self] in
                self?.apply(state)
            }
        }
        let readiness = await engine.prepare()
        guard readiness.isReady else {
            markUnavailable(permissionDenied: false)
            return
        }
        if let state = readiness.state {
            apply(state)
        }
        canCapture = true
        if previewLayer == nil {
            // 预览层只是个 CALayer，建在主线程上很轻；重活（设备发现、
            // addInput/commitConfiguration、startRunning）都在 engine 的队列上。
            let layer = AVCaptureVideoPreviewLayer(session: engine.session)
            layer.videoGravity = .resizeAspectFill
            // App 锁定竖屏，取景连接固定 90°。用 iOS 17 起的 videoRotationAngle，
            // 不用已废弃的 videoOrientation。
            if let connection = layer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            previewLayer = layer
        }
        engine.start()
    }

    func stop() {
        engine.stop()
    }

    func setFlashEnabled(_ enabled: Bool) {
        flashEnabled = enabled
    }

    func focusAndMeter(at devicePoint: CGPoint) {
        engine.focusAndMeter(at: devicePoint)
    }

    func setDisplayZoomFactor(_ factor: CGFloat) {
        let clamped = min(max(factor, minimumDisplayZoomFactor), maximumDisplayZoomFactor)
        displayZoomFactor = clamped
        engine.setDisplayZoomFactor(clamped)
    }

    func capturePhoto() async throws -> UIImage {
        guard canCapture else {
            throw isPermissionDenied ? CameraCaptureError.permissionDenied : CameraCaptureError.unavailable
        }
        let settings = AVCapturePhotoSettings()
        if engine.photoOutput.supportedFlashModes.contains(.on) {
            settings.flashMode = flashEnabled ? .on : .off
        }

        let token = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate { [weak self] result in
                self?.pendingCaptures[token] = nil
                continuation.resume(with: result)
            }
            pendingCaptures[token] = delegate
            // 与变焦配置走同一串行队列，确保快门排在最后一次捏合倍率之后。
            engine.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func markUnavailable(permissionDenied: Bool) {
        canCapture = false
        isFlashAvailable = false
        isPermissionDenied = permissionDenied
    }

    private func apply(_ state: CaptureEngine.CameraState) {
        isFlashAvailable = state.hasFlash
        isAdjustingFocus = state.isAdjustingFocus
        isAdjustingExposure = state.isAdjustingExposure
        focusPointOfInterest = state.focusPointOfInterest
        displayZoomFactor = state.displayZoomFactor
        minimumDisplayZoomFactor = state.minimumDisplayZoomFactor
        maximumDisplayZoomFactor = state.maximumDisplayZoomFactor
    }
}

/// 会话本体。`AVCaptureSession` 不是 Sendable，但配置与启停全部压在这一条串行队列上，
/// 由 `@unchecked Sendable` 把这个不变量写成类型约束——同 `MicrophoneAudioSource` 的做法。
///
/// `session` 对外只读用于绑定预览层；`photoOutput` 对外只读取闪光能力。
/// 拍照请求本身仍回到这条队列，排在最后一次变焦配置之后。
private final class CaptureEngine: @unchecked Sendable {
    struct CameraState: Sendable {
        let hasFlash: Bool
        let isAdjustingFocus: Bool
        let isAdjustingExposure: Bool
        let focusPointOfInterest: CGPoint
        let displayZoomFactor: CGFloat
        let minimumDisplayZoomFactor: CGFloat
        let maximumDisplayZoomFactor: CGFloat
    }

    struct Readiness: Sendable {
        let isReady: Bool
        let state: CameraState?
    }

    let session = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()

    /// `startRunning()`/`stopRunning()` 与会话配置都是阻塞调用，苹果明确要求放在专用串行队列。
    private let queue = DispatchQueue(label: "com.yspritan.verto.camera.session")
    private var device: AVCaptureDevice?
    private var isConfigured = false
    private var stateHandler: (@Sendable (CameraState) -> Void)?
    private var focusObservation: NSKeyValueObservation?
    private var exposureObservation: NSKeyValueObservation?
    private var focusPointObservation: NSKeyValueObservation?
    private var subjectAreaObserver: NSObjectProtocol?

    deinit {
        if let subjectAreaObserver {
            NotificationCenter.default.removeObserver(subjectAreaObserver)
        }
    }

    func setStateHandler(_ handler: @escaping @Sendable (CameraState) -> Void) {
        queue.async {
            self.stateHandler = handler
            self.reportState()
        }
    }

    func prepare() async -> Readiness {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.configureIfNeeded())
            }
        }
    }

    func start() {
        queue.async {
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capturePhoto(
        with settings: AVCapturePhotoSettings,
        delegate: AVCapturePhotoCaptureDelegate
    ) {
        queue.async {
            // capturePhoto 只是向系统入队，不会把会话队列堵在照片处理上。
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func focusAndMeter(at devicePoint: CGPoint) {
        queue.async {
            guard let device = self.device else { return }
            self.configureContinuousAuto(
                on: device,
                at: CGPoint(
                    x: min(max(devicePoint.x, 0), 1),
                    y: min(max(devicePoint.y, 0), 1)
                )
            )
            self.reportState()
        }
    }

    func setDisplayZoomFactor(_ factor: CGFloat) {
        queue.async {
            guard let device = self.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            let multiplier = self.displayZoomMultiplier(for: device)
            let requestedDeviceFactor = factor / multiplier
            device.videoZoomFactor = min(
                max(requestedDeviceFactor, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor
            )
            device.unlockForConfiguration()
            self.reportState()
        }
    }

    private func configureIfNeeded() -> Readiness {
        if isConfigured {
            guard let device else { return Readiness(isReady: false, state: nil) }
            // 页面重进或 App 回前台时，不能沿用系统中断前可能残留的锁定/单次模式。
            configureContinuousAuto(on: device, at: CGPoint(x: 0.5, y: 0.5))
            let state = makeState(for: device)
            stateHandler?(state)
            return Readiness(isReady: true, state: state)
        }
        // 模拟器没有摄像头，这里就是 nil——不可用性是运行时判定，不是 #if targetEnvironment。
        guard let device = Self.preferredBackCamera(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(photoOutput) else {
            return Readiness(isReady: false, state: nil)
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        session.addOutput(photoOutput)
        // 连接要在 addOutput 之后才存在，取角度必须放在 commitConfiguration 之前。
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        session.commitConfiguration()

        self.device = device
        isConfigured = true
        installDeviceObservers(for: device)
        configureContinuousAuto(
            on: device,
            at: CGPoint(x: 0.5, y: 0.5),
            resetToOneTimesZoom: true
        )
        let state = makeState(for: device)
        stateHandler?(state)
        return Readiness(isReady: true, state: state)
    }

    /// 虚拟设备由系统在各实体镜头间切换；只有设备没有对应组合时才退回单广角。
    private static func preferredBackCamera() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        return preferredTypes.lazy.compactMap {
            AVCaptureDevice.default($0, for: .video, position: .back)
        }.first
    }

    private func configureContinuousAuto(
        on device: AVCaptureDevice,
        at point: CGPoint,
        resetToOneTimesZoom: Bool = false
    ) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if device.primaryConstituentDeviceSwitchingBehavior != .unsupported {
            // `.auto` 才允许系统按焦距、光线与最近对焦距离选择更合适的实体镜头。
            device.setPrimaryConstituentDeviceSwitchingBehavior(
                .auto,
                restrictedSwitchingBehaviorConditions: []
            )
        }
        if resetToOneTimesZoom {
            // 虚拟三摄的设备 1.0 可能是界面 0.5×；首次打开要延续原单广角的 1× 构图。
            let oneTimesDeviceFactor = 1 / displayZoomMultiplier(for: device)
            device.videoZoomFactor = min(
                max(oneTimesDeviceFactor, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor
            )
        }
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.isSubjectAreaChangeMonitoringEnabled = true
    }

    private func installDeviceObservers(for device: AVCaptureDevice) {
        let report: () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async { self.reportState() }
        }
        focusObservation = device.observe(\.isAdjustingFocus, options: [.initial, .new]) { _, _ in report() }
        exposureObservation = device.observe(\.isAdjustingExposure, options: [.initial, .new]) { _, _ in report() }
        focusPointObservation = device.observe(\.focusPointOfInterest, options: [.initial, .new]) { _, _ in report() }
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceSubjectAreaDidChange,
            object: device,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard let device = self.device else { return }
                // 主体显著变化后回到整幅画面中心继续追焦/测光，避免一次点按永久钉住旧区域。
                self.configureContinuousAuto(on: device, at: CGPoint(x: 0.5, y: 0.5))
                self.reportState()
            }
        }
    }

    private func reportState() {
        guard let device else { return }
        stateHandler?(makeState(for: device))
    }

    private func makeState(for device: AVCaptureDevice) -> CameraState {
        let multiplier = displayZoomMultiplier(for: device)
        let minimum = device.minAvailableVideoZoomFactor * multiplier
        let deviceMaximum = device.maxAvailableVideoZoomFactor * multiplier
        // 产品只承诺显示到 5×；低于 5× 的设备仍严格服从真实硬件上限。
        let maximum = max(minimum, min(5, deviceMaximum))
        return CameraState(
            hasFlash: device.hasFlash,
            isAdjustingFocus: device.isAdjustingFocus,
            isAdjustingExposure: device.isAdjustingExposure,
            focusPointOfInterest: device.focusPointOfInterest,
            displayZoomFactor: min(max(device.videoZoomFactor * multiplier, minimum), maximum),
            minimumDisplayZoomFactor: minimum,
            maximumDisplayZoomFactor: maximum
        )
    }

    private func displayZoomMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) {
            // 这是系统相机界面使用的展示换算；例如实体 1× 可显示为虚拟三摄的 0.5×。
            return device.displayVideoZoomFactorMultiplier
        }
        if device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera,
           let wideSwitchFactor = device.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue,
           wideSwitchFactor > 0 {
            // iOS 17 没有系统展示系数；含超广角的虚拟设备在首个切镜点才对应界面 1×。
            return 1 / CGFloat(wideSwitchFactor)
        }
        return 1
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: @MainActor (Result<UIImage, Error>) -> Void

    init(completion: @escaping @MainActor (Result<UIImage, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // fileDataRepresentation 带完整 EXIF，UIImage(data:) 据此填好 imageOrientation；
        // 直接取 cgImageRepresentation 会丢方向，Vision 会把竖持拍的照片当横排识别。
        let result: Result<UIImage, Error>
        if error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) {
            result = .success(image)
        } else {
            result = .failure(CameraCaptureError.captureFailed)
        }
        // 回调线程由系统决定；状态与 continuation 都归主线程。
        let completion = completion
        Task { @MainActor in completion(result) }
    }
}

/// 取景层宿主。`layerClass` 直接是预览层，省掉一层手工 frame 同步。
struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.layer.addSublayer(previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer = previewLayer
        if previewLayer.superlayer !== uiView.layer {
            previewLayer.removeFromSuperlayer()
            uiView.layer.addSublayer(previewLayer)
        }
    }

    final class PreviewContainerView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            // 预览层不参与 Auto Layout，每次布局手工对齐到容器边界。
            // CATransaction 关隐式动画，否则旋转/尺寸变化会看到一次拉伸补间。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

extension UIImage {
    /// 把 EXIF 方向烘进像素，返回 `.up` 正立图。
    ///
    /// 竖持手机拍出来的照片实际是横向位图 + `.right` 方向标记。识别、显示、
    /// 取色三处都按块坐标读这张图，只要还留着方向标记，就得指望三处各自记得
    /// 转一次——在入口烘平一次，三处共用一套坐标，整类方向错位不可能发生。
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        // size 已是「按方向摆正后」的尺寸，draw(in:) 会顺带应用方向。
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
