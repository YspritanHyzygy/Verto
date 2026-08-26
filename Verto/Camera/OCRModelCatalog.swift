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

/// 三档模型共用的安装状态机，也是设备路由读取的唯一模型健康状态。
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

    enum EffectiveEngine: Equatable {
        case model(OCRModelTier)
        case vision
    }

    private static let testSelectionKey = "ocrTest.selection"
    private(set) var testSelection: OCRTestSelection

    private let installer: OCRModelPackInstalling
    let policy: OCRRoutingPolicy
    /// 只有 OCR Test 构建传入。生产为 nil，因此没有人工覆盖入口。
    @ObservationIgnored private let testDefaults: UserDefaults?
    @ObservationIgnored private let modelHealthCheck: @Sendable (InstalledOCRModel) async -> Bool
    /// 每档一个在飞任务，重复触发不会并发下载两份。
    private var tasks: [OCRModelTier: Task<Bool, Never>] = [:]
    private var preparationTask: Task<Void, Never>?
    /// 加载或推理失败后，本次 App 会话不再反复撞同一坏模型。
    private var unhealthyTiers: Set<OCRModelTier> = []
    private var cachedRecognizers: [OCRModelTier: (
        model: InstalledOCRModel,
        service: PaddleTextRecognitionService
    )] = [:]

    init(
        installer: OCRModelPackInstalling,
        policy: OCRRoutingPolicy = OCRRoutingPolicy(
            machineIdentifier: OCRHardwareIdentifier.current()
        ),
        testDefaults: UserDefaults? = nil,
        modelHealthCheck: @escaping @Sendable (InstalledOCRModel) async -> Bool = { model in
            await Task.detached {
                (try? PaddleTextRecognitionService(model: model)) != nil
            }.value
        }
    ) {
        self.installer = installer
        self.policy = policy
        self.testDefaults = testDefaults
        self.modelHealthCheck = modelHealthCheck
        testSelection = testDefaults?.string(forKey: Self.testSelectionKey)
            .flatMap(OCRTestSelection.init(rawValue:)) ?? .automatic
        refreshInstalledStates()
    }

    /// 扫描磁盘同步一次状态。启动时以及删除后调用——磁盘是唯一事实来源，
    /// 不另外维护一份"我以为装了什么"的持久化记录。
    func refreshInstalledStates() {
        for tier in OCRModelTier.allCases where !(states[tier]?.isBusy ?? false) {
            states[tier] = installer.installed(tier) == nil ? .notInstalled : .installed
        }
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

    var routedModelTiers: [OCRModelTier] {
        policy.candidates(for: nil, testSelection: testSelection).compactMap { candidate in
            guard case .model(let tier) = candidate else { return nil }
            return tier
        }
    }

    /// App 根视图每次冷启动调用一次。主档结束后才开始备用档，避免两个
    /// Core ML 包同时抢网络、磁盘和编译资源；相机不会等待这个任务。
    @discardableResult
    func prepareAutomaticModelsIfNeeded() -> Task<Void, Never>? {
        if let preparationTask { return preparationTask }
        let tiers = routedModelTiers
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for tier in tiers where self.installer.installed(tier) == nil {
                _ = await self.startInstall(tier).value
            }

            // OCR Test 要保留三档供人工来回测，不能套生产清理策略。
            guard self.testDefaults == nil else { return }
            var allRoutedModelsAreHealthy = true
            for tier in tiers {
                guard let model = self.installer.installed(tier),
                      await self.modelHealthCheck(model) else {
                    self.unhealthyTiers.insert(tier)
                    allRoutedModelsAreHealthy = false
                    continue
                }
                self.unhealthyTiers.remove(tier)
            }
            // 先确认两档都完整且能加载，再清掉不属于本机链的旧包。否则一次
            // 损坏下载会同时拿走用户原来还能测试/回退的模型。
            if tiers.isEmpty || allRoutedModelsAreHealthy {
                self.removeModels(outside: Set(tiers))
            }
        }
        return preparationTask
    }

    // MARK: - OCR Test 操作

    func selectTestEngine(_ selection: OCRTestSelection) {
        guard testDefaults != nil else { return }
        testSelection = selection
        testDefaults?.set(selection.rawValue, forKey: Self.testSelectionKey)
        if let tier = selection.tier, installer.installed(tier) == nil {
            install(tier)
        } else if selection == .automatic {
            preparationTask?.cancel()
            preparationTask = nil
            prepareAutomaticModelsIfNeeded()
        }
    }

    func install(_ tier: OCRModelTier) {
        _ = startInstall(tier)
    }

    func cancel(_ tier: OCRModelTier) {
        tasks[tier]?.cancel()
        tasks[tier] = nil
        states[tier] = installer.installed(tier) == nil ? .notInstalled : .installed
    }

    func delete(_ tier: OCRModelTier) {
        cancel(tier)
        cachedRecognizers[tier] = nil
        unhealthyTiers.remove(tier)
        try? installer.remove(tier)
        refreshInstalledStates()
    }

    // MARK: - 路由

    func effectiveEngine(for language: Language?) -> EffectiveEngine {
        for candidate in policy.candidates(for: language, testSelection: testSelection) {
            switch candidate {
            case .model(let tier):
                if installer.installed(tier) != nil, !unhealthyTiers.contains(tier) {
                    return .model(tier)
                }
            case .vision:
                return .vision
            }
        }
        return .vision
    }

    var preferredModelTier: OCRModelTier? { routedModelTiers.first }

    /// 加载失败会立即剔除；推理失败由路由器回报后也会在本次会话里剔除。
    func makeRecognizer(system: any TextRecognitionService) -> any TextRecognitionService {
        var candidates: [RoutingTextRecognitionService.ModelCandidate] = []
        for tier in routedModelTiers where !unhealthyTiers.contains(tier) {
            guard let model = installer.installed(tier) else { continue }
            if cachedRecognizers[tier]?.model != model {
                do {
                    cachedRecognizers[tier] = (
                        model,
                        try PaddleTextRecognitionService(model: model)
                    )
                } catch {
                    unhealthyTiers.insert(tier)
                    continue
                }
            }
            if let service = cachedRecognizers[tier]?.service {
                candidates.append(.init(tier: tier, service: service))
            }
        }
        guard !candidates.isEmpty else { return system }

        return RoutingTextRecognitionService(
            models: candidates,
            system: system,
            onModelFailure: { [weak self] tier in
                Task { @MainActor in self?.markUnhealthy(tier) }
            }
        )
    }

    private func markUnhealthy(_ tier: OCRModelTier) {
        unhealthyTiers.insert(tier)
        cachedRecognizers[tier] = nil
    }

    // MARK: - 安装细节

    private func startInstall(_ tier: OCRModelTier) -> Task<Bool, Never> {
        if let existing = tasks[tier] { return existing }
        if installer.installed(tier) != nil {
            states[tier] = .installed
            return Task { true }
        }

        states[tier] = .downloading(0)
        let task = Task { @MainActor [weak self, installer] in
            guard let self else { return false }
            let succeeded: Bool
            do {
                _ = try await installer.install(tier) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.apply(progress: progress, to: tier) }
                }
                self.states[tier] = .installed
                self.unhealthyTiers.remove(tier)
                succeeded = true
            } catch is CancellationError {
                self.states[tier] = installer.installed(tier) == nil ? .notInstalled : .installed
                succeeded = false
            } catch {
                self.states[tier] = .failed(
                    (error as? OCRModelInstallError) ?? .network
                )
                succeeded = false
            }
            self.tasks[tier] = nil
            return succeeded
        }
        tasks[tier] = task
        return task
    }

    private func apply(progress: Double, to tier: OCRModelTier) {
        guard case .downloading = states[tier] else { return }
        states[tier] = progress >= 1 ? .installing : .downloading(progress)
    }

    private func removeModels(outside retained: Set<OCRModelTier>) {
        for tier in OCRModelTier.allCases where !retained.contains(tier) {
            guard installer.installed(tier) != nil else { continue }
            cachedRecognizers[tier] = nil
            unhealthyTiers.remove(tier)
            try? installer.remove(tier)
        }
        refreshInstalledStates()
    }
}
