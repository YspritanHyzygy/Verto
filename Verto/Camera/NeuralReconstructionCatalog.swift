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

import CoreML
import CryptoKit
import Darwin
import Foundation
import Metal
import Network
import Observation
import UIKit

struct NeuralReconstructionReleaseDescriptor: Sendable {
    let archiveURL: URL
    let archiveName: String
    let downloadBytes: Int64
    let sha256: String
    let installDirectory: URL
    let sourceModelName: String
    let compiledModelName: String

    var artifact: ModelArtifactDescriptor {
        ModelArtifactDescriptor(
            id: "neural-reconstruction",
            archiveURL: archiveURL,
            archiveName: archiveName,
            downloadBytes: downloadBytes,
            sha256: sha256,
            installDirectory: installDirectory
        )
    }
}

enum NeuralReconstructionRelease {
    /// The weight release and redistribution gate are still pending.
    /// Keep this nil until the exact archive, size, and SHA are published.
    static let published: NeuralReconstructionReleaseDescriptor? = nil
}

struct InstalledNeuralReconstructionModel: Equatable, Sendable {
    let directory: URL
    let modelURL: URL
}

struct NeuralReconstructionInstaller: Sendable {
    let descriptor: NeuralReconstructionReleaseDescriptor
    private let artifactInstaller: ModelArtifactInstaller

    init(
        descriptor: NeuralReconstructionReleaseDescriptor,
        artifactInstaller: ModelArtifactInstaller = ModelArtifactInstaller()
    ) {
        self.descriptor = descriptor
        self.artifactInstaller = artifactInstaller
    }

    func installed() -> InstalledNeuralReconstructionModel? {
        let modelURL = descriptor.installDirectory
            .appendingPathComponent(descriptor.compiledModelName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        return InstalledNeuralReconstructionModel(
            directory: descriptor.installDirectory,
            modelURL: modelURL
        )
    }

    func install(onProgress: @escaping @Sendable (Double) -> Void) async throws
        -> InstalledNeuralReconstructionModel {
        try await artifactInstaller.install(descriptor.artifact, onProgress: onProgress) {
            unpacked, staging in
            let source = unpacked.appendingPathComponent(descriptor.sourceModelName)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw OCRModelInstallError.extractionFailed
            }
            let compiled: URL
            do {
                compiled = try await MLModel.compileModel(at: source)
            } catch {
                throw OCRModelInstallError.compilationFailed
            }
            let target = staging.appendingPathComponent(
                descriptor.compiledModelName,
                isDirectory: true
            )
            try FileManager.default.moveItem(at: compiled, to: target)

            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            _ = try MLModel(contentsOf: target, configuration: configuration)
        }
        guard let model = installed() else { throw OCRModelInstallError.compilationFailed }
        return model
    }
}

struct NeuralReconstructionDeviceFacts: Equatable, Sendable {
    let isSimulator: Bool
    let isPhone: Bool
    let supportsApple7: Bool
    let identifierForVendor: String?
    let machine: String
    let kernelOSVersion: String

    static func current() -> Self {
#if targetEnvironment(simulator)
        let isSimulator = true
#else
        let isSimulator = false
#endif
        return Self(
            isSimulator: isSimulator,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            supportsApple7: MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) == true,
            identifierForVendor: UIDevice.current.identifierForVendor?.uuidString,
            machine: sysctlString("hw.machine"),
            kernelOSVersion: sysctlString("kern.osversion")
        )
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
}

enum NeuralReconstructionIneligibility: String, Equatable, Sendable {
    case simulator
    case notPhone
    case metalFamily
    case missingDeviceIdentity
}

enum NeuralReconstructionEligibility {
    static func reason(
        for facts: NeuralReconstructionDeviceFacts
    ) -> NeuralReconstructionIneligibility? {
        if facts.isSimulator { return .simulator }
        if !facts.isPhone { return .notPhone }
        if !facts.supportsApple7 { return .metalFamily }
        if facts.identifierForVendor == nil
            || facts.machine.isEmpty
            || facts.kernelOSVersion.isEmpty {
            return .missingDeviceIdentity
        }
        return nil
    }
}

enum NeuralReconstructionComputeRoute: String, Codable, Equatable, Sendable {
    case all
    case cpuAndGPU

    var computeUnits: MLComputeUnits {
        switch self {
        case .all: .all
        case .cpuAndGPU: .cpuAndGPU
        }
    }
}

struct NeuralReconstructionProbeFixture: Equatable, Hashable, Sendable {
    static let schemaVersion = 1
    static let version = "migan-512-fixture-1"

    let width: Int
    let height: Int
    let rgbBytes: Data
    let knownMaskBytes: Data

    static func production() -> Self {
        let width = 512
        let height = 512
        var rgb = Data(count: width * height * 3)
        var mask = Data(count: width * height)
        rgb.withUnsafeMutableBytes { raw in
            let values = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 3
                    values[offset] = UInt8((x * 255) / (width - 1))
                    values[offset + 1] = UInt8((y * 255) / (height - 1))
                    values[offset + 2] = UInt8(((x + y) * 255) / (width + height - 2))
                }
            }
        }
        mask.withUnsafeMutableBytes { raw in
            let values = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let isHole = (128..<384).contains(x) && (208..<304).contains(y)
                    values[y * width + x] = isHole ? 0 : 255
                }
            }
        }
        return Self(width: width, height: height, rgbBytes: rgb, knownMaskBytes: mask)
    }
}

struct NeuralReconstructionProbeSample: Equatable, Sendable {
    /// Normalized RGB output in a stable channel order chosen by the runner.
    let output: [Float]
}

enum NeuralReconstructionProbeFailure: Error, Equatable, Sendable {
    case interrupted(String)
    case transient(String)
    case deterministic(String)
}

typealias NeuralReconstructionProbeRunner = @Sendable (
    _ modelURL: URL,
    _ computeUnits: MLComputeUnits,
    _ fixture: NeuralReconstructionProbeFixture
) async throws -> NeuralReconstructionProbeSample

typealias NeuralPhotoReconstructorFactory = @Sendable (
    _ modelURL: URL,
    _ route: NeuralReconstructionComputeRoute
) throws -> NeuralPhotoBackgroundReconstructor

enum NeuralReconstructionProductionProbe {
    static func run(
        modelURL: URL,
        computeUnits: MLComputeUnits,
        fixture: NeuralReconstructionProbeFixture
    ) async throws -> NeuralReconstructionProbeSample {
        let kernel = try NeuralBackgroundReconstructor(
            modelURL: modelURL,
            computeUnits: computeUnits
        )
        let images = try makeImages(fixture)
        let output = try kernel.reconstruct(image: images.image, knownMask: images.mask)
        return NeuralReconstructionProbeSample(output: try normalizedRGB(output))
    }

    static func makeReconstructor(
        modelURL: URL,
        route: NeuralReconstructionComputeRoute
    ) throws -> NeuralPhotoBackgroundReconstructor {
        let kernel = try NeuralBackgroundReconstructor(
            modelURL: modelURL,
            computeUnits: route.computeUnits
        )
        let images = try makeImages(.production())
        _ = try kernel.reconstruct(image: images.image, knownMask: images.mask)
        return NeuralPhotoBackgroundReconstructor(kernel: kernel)
    }

    private static func makeImages(
        _ fixture: NeuralReconstructionProbeFixture
    ) throws -> (image: CGImage, mask: CGImage) {
        guard fixture.rgbBytes.count == fixture.width * fixture.height * 3,
              fixture.knownMaskBytes.count == fixture.width * fixture.height else {
            throw NeuralReconstructionProbeFailure.deterministic("Invalid fixture shape")
        }
        var rgba = [UInt8](repeating: 255, count: fixture.width * fixture.height * 4)
        fixture.rgbBytes.withUnsafeBytes { raw in
            let rgb = raw.bindMemory(to: UInt8.self)
            for index in 0..<(fixture.width * fixture.height) {
                rgba[index * 4] = rgb[index * 3]
                rgba[index * 4 + 1] = rgb[index * 3 + 1]
                rgba[index * 4 + 2] = rgb[index * 3 + 2]
            }
        }
        guard let imageProvider = CGDataProvider(data: Data(rgba) as CFData),
              let maskProvider = CGDataProvider(data: fixture.knownMaskBytes as CFData),
              let image = CGImage(
                width: fixture.width,
                height: fixture.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: fixture.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: imageProvider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let mask = CGImage(
                width: fixture.width,
                height: fixture.height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: fixture.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: maskProvider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw NeuralReconstructionProbeFailure.deterministic("Fixture image creation failed")
        }
        return (image, mask)
    }

    private static func normalizedRGB(_ image: CGImage) throws -> [Float] {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drew = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw NeuralReconstructionProbeFailure.deterministic("Probe output conversion failed")
        }
        var output = [Float]()
        output.reserveCapacity(width * height * 3)
        for index in 0..<(width * height) {
            output.append(Float(rgba[index * 4]) / 255)
            output.append(Float(rgba[index * 4 + 1]) / 255)
            output.append(Float(rgba[index * 4 + 2]) / 255)
        }
        return output
    }
}

struct NeuralReconstructionProbeKey: Codable, Equatable, Sendable {
    let identifierForVendor: String
    let machine: String
    let kernelOSVersion: String
    let modelTreeSHA256: String
    let sidecarSchemaVersion: Int
    let fixtureSchemaVersion: Int
    let fixtureVersion: String
}

enum NeuralReconstructionProbeAttemptStatus: String, Codable, Equatable, Sendable {
    case completed
    case interrupted
    case transientFailure
    case deterministicFailure
}

struct NeuralReconstructionProbeBackendFacts: Codable, Equatable, Sendable {
    let route: NeuralReconstructionComputeRoute
    let warmupCompleted: Bool
    let timingSeconds: [Double]
    let errorDescription: String?
}

struct NeuralReconstructionProbeParityFacts: Codable, Equatable, Sendable {
    let meanAbsoluteError: Double
    let fractionAbovePointZeroFive: Double
    let comparedValueCount: Int
}

struct NeuralReconstructionProbeSidecar: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let fileName = "neural-reconstruction-probe.json"

    let schemaVersion: Int
    let key: NeuralReconstructionProbeKey
    let recordedAt: Date
    let attemptNumber: Int
    let status: NeuralReconstructionProbeAttemptStatus
    let all: NeuralReconstructionProbeBackendFacts?
    let cpuAndGPU: NeuralReconstructionProbeBackendFacts?
    let parity: NeuralReconstructionProbeParityFacts?
    let errorDescription: String?
    let retryAfter: Date?
}

struct NeuralReconstructionProbeSidecarStore: Sendable {
    let modelDirectory: URL

    var url: URL {
        modelDirectory.appendingPathComponent(NeuralReconstructionProbeSidecar.fileName)
    }

    func load() -> NeuralReconstructionProbeSidecar? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NeuralReconstructionProbeSidecar.self, from: data)
    }

    func save(_ sidecar: NeuralReconstructionProbeSidecar) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sidecar)
        try data.write(to: url, options: [.atomic])
    }
}

enum NeuralReconstructionModelTreeHasher {
    static func sha256(of directory: URL) throws -> String {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw OCRModelInstallError.compilationFailed
        }
        let files = enumerator.compactMap { $0 as? URL }
            .filter {
                $0.lastPathComponent != NeuralReconstructionProbeSidecar.fileName
                    && (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
            }
            .sorted { $0.path < $1.path }

        var hasher = SHA256()
        for file in files {
            let relative = String(file.path.dropFirst(directory.path.count))
            let pathData = Data(relative.utf8)
            var pathLength = UInt64(pathData.count).bigEndian
            withUnsafeBytes(of: &pathLength) { hasher.update(data: Data($0)) }
            hasher.update(data: pathData)

            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum NeuralReconstructionProbeMath {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func parity(
        _ lhs: [Float],
        _ rhs: [Float],
        knownMaskBytes: Data? = nil
    ) -> NeuralReconstructionProbeParityFacts? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var absoluteTotal = 0.0
        var aboveThreshold = 0
        var compared = 0
        for index in lhs.indices {
            if let knownMaskBytes {
                let pixel = index / 3
                guard pixel < knownMaskBytes.count, knownMaskBytes[pixel] < 255 else { continue }
            }
            let left = lhs[index]
            let right = rhs[index]
            guard left.isFinite, right.isFinite else { return nil }
            let difference = abs(Double(left) - Double(right))
            absoluteTotal += difference
            if difference > 0.05 { aboveThreshold += 1 }
            compared += 1
        }
        guard compared > 0 else { return nil }
        return NeuralReconstructionProbeParityFacts(
            meanAbsoluteError: absoluteTotal / Double(compared),
            fractionAbovePointZeroFive: Double(aboveThreshold) / Double(compared),
            comparedValueCount: compared
        )
    }
}

enum NeuralReconstructionProbeEvaluation: Equatable, Sendable {
    case ready(NeuralReconstructionComputeRoute)
    case retry(Date)
    case rejected

    static func evaluate(
        _ sidecar: NeuralReconstructionProbeSidecar,
        now: Date
    ) -> Self {
        switch sidecar.status {
        case .interrupted, .transientFailure:
            return sidecar.retryAfter.map { .retry($0) } ?? .rejected
        case .deterministicFailure:
            return .rejected
        case .completed:
            break
        }

        let allMedian = sidecar.all.flatMap {
            $0.errorDescription == nil ? NeuralReconstructionProbeMath.median($0.timingSeconds) : nil
        }
        let cpuMedian = sidecar.cpuAndGPU.flatMap {
            $0.errorDescription == nil ? NeuralReconstructionProbeMath.median($0.timingSeconds) : nil
        }
        let parityAccepted = sidecar.parity.map {
            $0.meanAbsoluteError <= 0.01 && $0.fractionAbovePointZeroFive <= 0.01
        } ?? false

        if let allMedian, allMedian <= 1, parityAccepted { return .ready(.all) }
        if !parityAccepted, let cpuMedian, cpuMedian <= 1 {
            return .ready(.cpuAndGPU)
        }
        if sidecar.all?.errorDescription != nil, let cpuMedian, cpuMedian <= 1 {
            return .ready(.cpuAndGPU)
        }
        return .rejected
    }
}

@Observable
@MainActor
final class NeuralReconstructionCatalog {
    enum State: Equatable {
        case ineligible(NeuralReconstructionIneligibility)
        case unavailableForDownload
        case notInstalled
        case downloading(Double)
        case installing
        case waitingForProbeKernel
        case waitingForNominalConditions
        case backingOff(Date)
        case probing
        case ready(NeuralReconstructionComputeRoute)
        case rejected
        case failed(OCRModelInstallError)
    }

    private(set) var state: State

    private let deviceFacts: NeuralReconstructionDeviceFacts
    private let installer: NeuralReconstructionInstaller?
    private let probeRunner: NeuralReconstructionProbeRunner?
    private let reconstructorFactory: NeuralPhotoReconstructorFactory?
    private let fixture: NeuralReconstructionProbeFixture
    private let now: @Sendable () -> Date
    private var task: Task<Void, Never>?
    private var installedModel: InstalledNeuralReconstructionModel?
    private var preparedReconstructor: NeuralPhotoBackgroundReconstructor?
    private var preparationTask: Task<Void, Never>?
    private var preparationWorker: Task<NeuralPhotoBackgroundReconstructor?, Never>?
    private var preparationGeneration = 0
    private var readyMedianSeconds: Double?
    private var isForeground = true
    private var hadMemoryWarning = false
    private var isPhotoPageActive = false
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.yspritan.verto.neural-download-path")
    private var networkAllowsBackgroundDownload = false

    init(
        release: NeuralReconstructionReleaseDescriptor? = NeuralReconstructionRelease.published,
        artifactInstaller: ModelArtifactInstaller = ModelArtifactInstaller(),
        deviceFacts: NeuralReconstructionDeviceFacts = .current(),
        probeRunner: NeuralReconstructionProbeRunner? = nil,
        reconstructorFactory: NeuralPhotoReconstructorFactory? = nil,
        fixture: NeuralReconstructionProbeFixture = .production(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deviceFacts = deviceFacts
        self.installer = release.map {
            NeuralReconstructionInstaller(descriptor: $0, artifactInstaller: artifactInstaller)
        }
        self.probeRunner = probeRunner
        self.reconstructorFactory = reconstructorFactory
        self.fixture = fixture
        self.now = now

        if let reason = NeuralReconstructionEligibility.reason(for: deviceFacts) {
            state = .ineligible(reason)
            return
        }
        guard let installer else {
            state = .unavailableForDownload
            return
        }
        let installed = installer.installed()
        installedModel = installed
        state = installed == nil ? .notInstalled : .waitingForProbeKernel
        startNetworkMonitoring()
    }

    var canInstall: Bool {
        NeuralReconstructionEligibility.reason(for: deviceFacts) == nil && installer != nil
    }

    func installIfAvailable() {
        guard canInstall, let installer, task == nil else { return }
        state = .downloading(0)
        task = Task { [installer] in
            do {
                let model = try await installer.install { progress in
                    Task { @MainActor in self.applyInstallProgress(progress) }
                }
                installedModel = model
                state = probeRunner == nil ? .waitingForProbeKernel : .waitingForNominalConditions
                task = nil
                probeIfNeeded()
            } catch is CancellationError {
                state = .notInstalled
                task = nil
            } catch {
                state = .failed((error as? OCRModelInstallError) ?? .compilationFailed)
                task = nil
            }
        }
    }

    func requestBackgroundInstallForFuturePhoto(hasUnresolvedRegions: Bool) {
        guard hasUnresolvedRegions,
              networkAllowsBackgroundDownload,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        switch state {
        case .notInstalled, .failed:
            installIfAvailable()
        default:
            break
        }
    }

    func enterPhotoPage() {
        isPhotoPageActive = true
        probeIfNeeded()
        prepareRouteIfPossible()
    }

    func leavePhotoPage() {
        isPhotoPageActive = false
        clearStrongReferences()
    }

    func appDidEnterForeground() {
        isForeground = true
        hadMemoryWarning = false
        probeIfNeeded()
        if isPhotoPageActive { prepareRouteIfPossible() }
    }

    func appDidEnterBackground() {
        isForeground = false
        task?.cancel()
        clearStrongReferences()
    }

    func didReceiveMemoryWarning() {
        hadMemoryWarning = true
        task?.cancel()
        clearStrongReferences()
    }

    /// The caller asks for this only when starting a new photo reconstruction.
    /// Preparing a model never changes work already in flight.
    func routeForNextPhoto(regionCount: Int) -> PhotoReconstructionRoute {
        prepareRouteIfPossible()
        guard let preparedReconstructor,
              let readyMedianSeconds,
              NeuralReconstructionPolicy.allows(
                medianSeconds: readyMedianSeconds,
                regionCount: regionCount,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState,
                hadMemoryWarning: hadMemoryWarning
              ) else { return .adaptive }
        return .neural(preparedReconstructor)
    }

    func probeIfNeeded() {
        guard task == nil, let model = installedModel ?? installer?.installed() else { return }
        installedModel = model
        guard probeRunner != nil else {
            state = .waitingForProbeKernel
            return
        }
        guard nominalConditionsAllowProbe else {
            state = .waitingForNominalConditions
            return
        }

        let key: NeuralReconstructionProbeKey
        do {
            key = try makeProbeKey(model: model)
        } catch {
            state = .failed(.compilationFailed)
            return
        }
        let store = NeuralReconstructionProbeSidecarStore(modelDirectory: model.directory)
        if let saved = store.load(), saved.key == key {
            applySavedEvaluation(saved)
            if case .backingOff(let retryAfter) = state, retryAfter <= now() {
                startProbe(model: model, key: key, previous: saved, store: store)
            }
            return
        }
        startProbe(model: model, key: key, previous: nil, store: store)
    }

    private var nominalConditionsAllowProbe: Bool {
        isForeground
            && UIApplication.shared.applicationState == .active
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && ProcessInfo.processInfo.thermalState == .nominal
            && !hadMemoryWarning
    }

    private func applyInstallProgress(_ progress: Double) {
        guard case .downloading = state else { return }
        state = progress >= 1 ? .installing : .downloading(progress)
    }

    private func makeProbeKey(
        model: InstalledNeuralReconstructionModel
    ) throws -> NeuralReconstructionProbeKey {
        guard let identifier = deviceFacts.identifierForVendor else {
            throw OCRModelInstallError.compilationFailed
        }
        return NeuralReconstructionProbeKey(
            identifierForVendor: identifier,
            machine: deviceFacts.machine,
            kernelOSVersion: deviceFacts.kernelOSVersion,
            modelTreeSHA256: try NeuralReconstructionModelTreeHasher.sha256(of: model.directory),
            sidecarSchemaVersion: NeuralReconstructionProbeSidecar.schemaVersion,
            fixtureSchemaVersion: NeuralReconstructionProbeFixture.schemaVersion,
            fixtureVersion: NeuralReconstructionProbeFixture.version
        )
    }

    private func applySavedEvaluation(_ sidecar: NeuralReconstructionProbeSidecar) {
        switch NeuralReconstructionProbeEvaluation.evaluate(sidecar, now: now()) {
        case .ready(let route):
            state = .ready(route)
            let backend = route == .all ? sidecar.all : sidecar.cpuAndGPU
            readyMedianSeconds = backend.flatMap {
                NeuralReconstructionProbeMath.median($0.timingSeconds)
            }
            prepareRouteIfPossible()
        case .retry(let retryAfter):
            state = .backingOff(retryAfter)
        case .rejected:
            state = .rejected
        }
    }

    private func startProbe(
        model: InstalledNeuralReconstructionModel,
        key: NeuralReconstructionProbeKey,
        previous: NeuralReconstructionProbeSidecar?,
        store: NeuralReconstructionProbeSidecarStore
    ) {
        guard let probeRunner else { return }
        state = .probing
        task = Task {
            let attempt = (previous?.attemptNumber ?? 0) + 1
            do {
                let facts = try await Self.runProbe(
                    modelURL: model.modelURL,
                    fixture: fixture,
                    runner: probeRunner
                )
                let sidecar = NeuralReconstructionProbeSidecar(
                    schemaVersion: NeuralReconstructionProbeSidecar.schemaVersion,
                    key: key,
                    recordedAt: now(),
                    attemptNumber: attempt,
                    status: .completed,
                    all: facts.all,
                    cpuAndGPU: facts.cpuAndGPU,
                    parity: facts.parity,
                    errorDescription: nil,
                    retryAfter: nil
                )
                try store.save(sidecar)
                task = nil
                applySavedEvaluation(sidecar)
            } catch {
                let failure = Self.classify(error)
                let retryAfter: Date?
                let status: NeuralReconstructionProbeAttemptStatus
                switch failure {
                case .interrupted:
                    status = .interrupted
                    retryAfter = now().addingTimeInterval(Self.retryDelay(attempt: attempt))
                case .transient:
                    status = .transientFailure
                    retryAfter = now().addingTimeInterval(Self.retryDelay(attempt: attempt))
                case .deterministic:
                    status = .deterministicFailure
                    retryAfter = nil
                }
                let sidecar = NeuralReconstructionProbeSidecar(
                    schemaVersion: NeuralReconstructionProbeSidecar.schemaVersion,
                    key: key,
                    recordedAt: now(),
                    attemptNumber: attempt,
                    status: status,
                    all: nil,
                    cpuAndGPU: nil,
                    parity: nil,
                    errorDescription: failure.description,
                    retryAfter: retryAfter
                )
                try? store.save(sidecar)
                task = nil
                applySavedEvaluation(sidecar)
            }
        }
    }

    struct ProbeRunFacts {
        let all: NeuralReconstructionProbeBackendFacts
        let cpuAndGPU: NeuralReconstructionProbeBackendFacts
        let parity: NeuralReconstructionProbeParityFacts?
    }

    static func runProbe(
        modelURL: URL,
        fixture: NeuralReconstructionProbeFixture,
        runner: NeuralReconstructionProbeRunner
    ) async throws -> ProbeRunFacts {
        let all = await runBackend(
            route: .all,
            modelURL: modelURL,
            fixture: fixture,
            runner: runner
        )
        if let error = all.error {
            switch classify(error) {
            case .interrupted, .transient: throw error
            case .deterministic: break
            }
        }
        try Task.checkCancellation()
        let cpuAndGPU = await runBackend(
            route: .cpuAndGPU,
            modelURL: modelURL,
            fixture: fixture,
            runner: runner
        )
        if let error = cpuAndGPU.error {
            switch classify(error) {
            case .interrupted, .transient: throw error
            case .deterministic: break
            }
        }
        try Task.checkCancellation()
        let parity: NeuralReconstructionProbeParityFacts? = if let allOutput = all.output,
                                                              let cpuOutput = cpuAndGPU.output {
            NeuralReconstructionProbeMath.parity(
                allOutput,
                cpuOutput,
                knownMaskBytes: fixture.knownMaskBytes
            )
        } else {
            nil
        }
        return ProbeRunFacts(all: all.facts, cpuAndGPU: cpuAndGPU.facts, parity: parity)
    }

    private struct BackendRun {
        let facts: NeuralReconstructionProbeBackendFacts
        let output: [Float]?
        let error: Error?
    }

    private static func runBackend(
        route: NeuralReconstructionComputeRoute,
        modelURL: URL,
        fixture: NeuralReconstructionProbeFixture,
        runner: NeuralReconstructionProbeRunner
    ) async -> BackendRun {
        do {
            _ = try await runner(modelURL, route.computeUnits, fixture)
            try Task.checkCancellation()
            var timings: [Double] = []
            var output: [Float] = []
            for _ in 0..<3 {
                let clock = ContinuousClock()
                let start = clock.now
                output = try await runner(modelURL, route.computeUnits, fixture).output
                guard output.count == fixture.width * fixture.height * 3,
                      output.allSatisfy(\.isFinite) else {
                    throw NeuralReconstructionProbeFailure.deterministic(
                        "Probe output shape or values are invalid"
                    )
                }
                let elapsed = start.duration(to: clock.now).components
                timings.append(
                    Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
                )
                try Task.checkCancellation()
            }
            return BackendRun(
                facts: NeuralReconstructionProbeBackendFacts(
                    route: route,
                    warmupCompleted: true,
                    timingSeconds: timings,
                    errorDescription: nil
                ),
                output: output,
                error: nil
            )
        } catch {
            let failure = classify(error)
            return BackendRun(
                facts: NeuralReconstructionProbeBackendFacts(
                    route: route,
                    warmupCompleted: false,
                    timingSeconds: [],
                    errorDescription: failure.description
                ),
                output: nil,
                error: failure
            )
        }
    }

    private static func retryDelay(attempt: Int) -> TimeInterval {
        min(300 * pow(2, Double(max(attempt - 1, 0))), 86_400)
    }

    private static func classify(_ error: Error) -> NeuralReconstructionProbeFailure {
        if error is CancellationError || Task.isCancelled {
            return .interrupted("Probe interrupted")
        }
        if let failure = error as? NeuralReconstructionProbeFailure { return failure }
        if error is URLError { return .transient(String(describing: error)) }
        return .deterministic(String(describing: error))
    }

    private func prepareRouteIfPossible() {
        guard isPhotoPageActive,
              isForeground,
              preparedReconstructor == nil,
              preparationTask == nil,
              let installedModel,
              let reconstructorFactory,
              case .ready(let route) = state else { return }
        preparationGeneration += 1
        let generation = preparationGeneration
        let worker = Task.detached(priority: .utility) {
            try? reconstructorFactory(installedModel.modelURL, route)
        }
        preparationWorker = worker
        preparationTask = Task { [weak self] in
            let reconstructor = await worker.value
            guard let self,
                  !Task.isCancelled,
                  generation == preparationGeneration,
                  isPhotoPageActive,
                  isForeground else { return }
            preparedReconstructor = reconstructor
            preparationTask = nil
            preparationWorker = nil
        }
    }

    private func clearStrongReferences() {
        preparationGeneration += 1
        preparationTask?.cancel()
        preparationTask = nil
        preparationWorker?.cancel()
        preparationWorker = nil
        preparedReconstructor = nil
    }

    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied
                && !path.usesInterfaceType(.cellular)
                && !path.isConstrained
            Task { @MainActor [weak self] in
                self?.networkAllowsBackgroundDownload = allowed
            }
        }
        networkMonitor.start(queue: networkQueue)
    }
}

private extension NeuralReconstructionProbeFailure {
    var description: String {
        switch self {
        case .interrupted(let message), .transient(let message), .deterministic(let message):
            message
        }
    }
}
