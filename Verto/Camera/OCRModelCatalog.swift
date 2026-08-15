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

import Foundation
import Observation

/// 三档模型的安装状态机，设置页与相机页共用一份。
///
/// 由 `AppShell` 持有：下载可能跨越标签页切换，状态挂在页面上会被销毁。
@Observable
@MainActor
final class OCRModelCatalog {
    enum State: Equatable {
        case notInstalled
        /// 取值 0...1。
        case downloading(Double)
        /// 已下完，正在校验/解包/编译。这一段没有可靠进度，单独成态。
        case installing
        case installed
        case failed(OCRModelInstallError)

        var isBusy: Bool {
            switch self {
            case .downloading, .installing: true
            case .notInstalled, .installed, .failed: false
            }
        }
    }

    private(set) var states: [OCRModelTier: State] = [:]

    /// 用户选中的档位。选中不等于已安装——选了才会去下。
    private(set) var selectedTier: OCRModelTier

    /// 当前真正能用的模型。相机页据此决定走高精度引擎还是系统引擎。
    private(set) var activeModel: InstalledOCRModel?

    private let installer: OCRModelPackInstalling
    private let settings: AppSettings
    /// 每档一个在飞任务，重复点下载不会并发起两份。
    private var tasks: [OCRModelTier: Task<Void, Never>] = [:]
    /// 首次自动下载只触发一次，来回切标签页不会反复起任务。
    private var didAutoInstall = false
    /// 已加载的高精度识别器。Core ML 编译产物在旧机器上要几百毫秒才加载得完，
    /// 每次快门都重建会让每张照片都慢一拍，所以按 activeModel 缓存。
    private var cachedRecognizer: (model: InstalledOCRModel, service: PaddleTextRecognitionService)?

    init(installer: OCRModelPackInstalling, settings: AppSettings) {
        self.installer = installer
        self.settings = settings
        selectedTier = settings.ocrModelTier
        refreshInstalledStates()
    }

    /// 扫描磁盘同步一次状态。启动时以及删除后调用——磁盘是唯一事实来源，
    /// 不另外维护一份"我以为装了什么"的持久化记录。
    func refreshInstalledStates() {
        for tier in OCRModelTier.allCases where !(states[tier]?.isBusy ?? false) {
            states[tier] = installer.installed(tier) == nil ? .notInstalled : .installed
        }
        activeModel = installer.installed(selectedTier)
    }

    func state(of tier: OCRModelTier) -> State { states[tier] ?? .notInstalled }

    func diskUsage(of tier: OCRModelTier) -> Int64 { installer.diskUsage(tier) }

    var totalDiskUsage: Int64 {
        OCRModelTier.allCases.reduce(0) { $0 + installer.diskUsage($1) }
    }

    /// 是否有任一档已装好。设置页用它决定要不要显示"当前由系统引擎识别"的提示。
    var hasAnyInstalledModel: Bool {
        OCRModelTier.allCases.contains { installer.installed($0) != nil }
    }

    // MARK: - 用户操作

    func select(_ tier: OCRModelTier) {
        selectedTier = tier
        settings.ocrModelTier = tier
        activeModel = installer.installed(tier)
        if activeModel == nil, !state(of: tier).isBusy {
            install(tier)
        }
    }

    func install(_ tier: OCRModelTier) {
        guard !(states[tier]?.isBusy ?? false) else { return }
        states[tier] = .downloading(0)
        tasks[tier]?.cancel()
        // 全程强持有 self：catalog 由 AppShell 持有、与 app 同寿，而下载中途
        // 把它放掉只会让状态永远停在"下载中"。这里没有循环引用风险——
        // 任务结束时会把自己从 tasks 里摘掉。
        tasks[tier] = Task { [installer] in
            do {
                let model = try await installer.install(tier) { progress in
                    Task { @MainActor in self.apply(progress: progress, to: tier) }
                }
                await MainActor.run {
                    self.states[tier] = .installed
                    if tier == self.selectedTier { self.activeModel = model }
                }
            } catch is CancellationError {
                await MainActor.run { self.states[tier] = .notInstalled }
            } catch {
                await MainActor.run {
                    self.states[tier] = .failed((error as? OCRModelInstallError) ?? .network)
                }
            }
            await MainActor.run { self.tasks[tier] = nil }
        }
    }

    /// 只在仍处于下载态时写进度：安装/失败/取消之后到达的回调是过期的，
    /// 写回去会让状态倒退。
    private func apply(progress: Double, to tier: OCRModelTier) {
        guard case .downloading = states[tier] else { return }
        // 进度到 1 表示字节收齐，后面是校验/解包/编译。那一段没有可靠进度
        // （Core ML 编译不报进度），所以换成独立的忙态，免得进度条停在
        // 100% 让人以为卡死。
        states[tier] = progress >= 1 ? .installing : .downloading(progress)
    }

    func cancel(_ tier: OCRModelTier) {
        tasks[tier]?.cancel()
        tasks[tier] = nil
        states[tier] = .notInstalled
    }

    func delete(_ tier: OCRModelTier) {
        cancel(tier)
        // 必须连缓存一起丢：重装同一档后 URL 完全相同，`InstalledOCRModel`
        // 因此判等成立，缓存会被误认为仍然有效——而它持有的 MLModel 指向的是
        // 已被删掉的那份文件。
        if cachedRecognizer?.model.tier == tier { cachedRecognizer = nil }
        try? installer.remove(tier)
        refreshInstalledStates()
    }

    /// 组装当前该用的识别器。
    ///
    /// 没装模型、加载失败、以及模型盖不住的语言，一律回落到 `system`——
    /// 高精度识别是增强不是前提，任何一环缺失都不该让相机页不能用。
    func makeRecognizer(system: any TextRecognitionService) -> any TextRecognitionService {
        guard let activeModel else { return system }
        if cachedRecognizer?.model != activeModel {
            cachedRecognizer = (try? PaddleTextRecognitionService(model: activeModel))
                .map { (activeModel, $0) }
        }
        return RoutingTextRecognitionService(
            highAccuracy: cachedRecognizer?.service,
            tier: activeModel.tier,
            system: system
        )
    }

    /// 首次进入相机页时触发默认档下载。用户没装过任何档才下——
    /// 已经装过又主动删掉的人，不该被再塞回来一次。
    func autoInstallDefaultIfNeeded() {
        guard !didAutoInstall else { return }
        didAutoInstall = true
        guard !hasAnyInstalledModel, settings.allowsAutomaticOCRModelDownload else { return }
        select(.default)
    }
}
