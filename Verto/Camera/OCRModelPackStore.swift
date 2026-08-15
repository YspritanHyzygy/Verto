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

import AppleArchive
import CoreML
import CryptoKit
import Foundation
import Observation
import System

/// 一档模型在磁盘上的成品：已编译的两个模型与字符表。
struct InstalledOCRModel: Equatable, Sendable {
    let tier: OCRModelTier
    /// `.mlmodelc`，`MLModel(contentsOf:)` 可直接加载。
    let detectorURL: URL
    let recognizerURL: URL
    let charactersURL: URL
}

enum OCRModelInstallError: LocalizedError, Equatable {
    case network
    case checksumMismatch
    case extractionFailed
    case compilationFailed
    case insufficientStorage
    case cancelled

    var errorDescription: String? {
        switch self {
        case .network: String(localized: "模型下载失败，请检查网络后重试")
        case .checksumMismatch: String(localized: "模型文件校验未通过，请重新下载")
        case .extractionFailed, .compilationFailed: String(localized: "模型安装失败，请重新下载")
        case .insufficientStorage: String(localized: "存储空间不足，请清理后重试")
        case .cancelled: nil
        }
    }
}

/// 下载并安装一档模型。抽成协议是为了让测试能在不联网的前提下驱动状态机，
/// 罐头实现放在 `CannedOCRModelInstaller`（仅 DEBUG）。
protocol OCRModelPackInstalling: Sendable {
    /// 全流程：下载 → 校验 → 解包 → 编译。进度回调取值 0...1。
    /// 抛 `CancellationError` 或 `OCRModelInstallError.cancelled` 表示被取消。
    func install(
        _ tier: OCRModelTier,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledOCRModel

    /// 已安装则返回成品，否则 nil。不触发任何下载。
    func installed(_ tier: OCRModelTier) -> InstalledOCRModel?

    func remove(_ tier: OCRModelTier) throws

    /// 该档在磁盘上实际占用的字节数；未安装为 0。
    func diskUsage(_ tier: OCRModelTier) -> Int64
}

/// 真实实现：URLSession 下载 + CryptoKit 校验 + AppleArchive 解包 + Core ML 编译。
struct OCRModelPackInstaller: OCRModelPackInstalling {
    /// 编译产物的文件名。`.mlmodelc` 是编译后的目录形式。
    private static let compiledDetector = "Detector.mlmodelc"
    private static let compiledRecognizer = "Recognizer.mlmodelc"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func installed(_ tier: OCRModelTier) -> InstalledOCRModel? {
        guard let root = try? OCRModelPack.installDirectory(for: tier) else { return nil }
        let model = InstalledOCRModel(
            tier: tier,
            detectorURL: root.appendingPathComponent(Self.compiledDetector),
            recognizerURL: root.appendingPathComponent(Self.compiledRecognizer),
            charactersURL: root.appendingPathComponent(OCRModelPack.charactersFileName)
        )
        let fm = FileManager.default
        // 三个产物齐全才算装好。半成品（下到一半被杀）要当成未安装重来，
        // 否则加载时才炸，而那时用户正等着识别结果。
        guard [model.detectorURL, model.recognizerURL, model.charactersURL]
            .allSatisfy({ fm.fileExists(atPath: $0.path) }) else {
            return nil
        }
        return model
    }

    func remove(_ tier: OCRModelTier) throws {
        let root = try OCRModelPack.installDirectory(for: tier)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func diskUsage(_ tier: OCRModelTier) -> Int64 {
        guard let root = try? OCRModelPack.installDirectory(for: tier),
              let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
              ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                .totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
        return total
    }

    func install(
        _ tier: OCRModelTier,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledOCRModel {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-install-\(tier.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let archive = scratch.appendingPathComponent(tier.archiveName)
        try await download(tier, to: archive, onProgress: onProgress)
        try Task.checkCancellation()

        guard try checksum(of: archive) == tier.sha256 else {
            throw OCRModelInstallError.checksumMismatch
        }

        let unpacked = scratch.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try extract(archive: archive, to: unpacked)
        try Task.checkCancellation()

        return try await compileAndInstall(tier: tier, from: unpacked)
    }

    // MARK: - 下载

    private func download(
        _ tier: OCRModelTier,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // 用 download(from:delegate:) 而不是 bytes(from:)：后者是逐**字节**的
        // AsyncSequence，medium 档 47MB 就是四千七百万次异步迭代，实测只有个位数
        // MB/s。download 直接落临时文件，进度经 delegate 回调。
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let (temporary, response) = try await session.download(
            from: tier.archiveURL, delegate: delegate
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw OCRModelInstallError.network
        }
        // download 返回后临时文件随时可能被系统回收，必须立刻挪走。
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw OCRModelInstallError.insufficientStorage
        }
        onProgress(1)

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? Int64
        guard size == tier.downloadBytes else {
            // 长度对不上说明下到一半断了，或者服务端换了文件——两种都不能装。
            throw OCRModelInstallError.network
        }
    }

    /// 只为把 `URLSessionDownloadTask` 的进度接出来。`@unchecked Sendable`：
    /// 内部只有一个不可变的 `@Sendable` 闭包，URLSession 从哪条线程回调都安全。
    private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate,
                                                   URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double) -> Void

        init(onProgress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            // 进度到 1 由调用方在落位后自己发，这里封顶在 0.99——
            // 否则会在校验/解包/编译还没开始时就先跳成"完成"。
            onProgress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.99))
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // async 版 download(from:delegate:) 自己接管文件搬运，这里无需处理。
        }
    }

    // MARK: - 校验

    /// 流式算 SHA-256。整包读进内存再算会在 medium 档（47MB）上无谓地翻倍占用。
    private func checksum(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 解包

    /// AppleArchive 解包。iOS 没有公开的解 zip API，所以模型包用 .aar 分发。
    private func extract(archive: URL, to directory: URL) throws {
        guard let source = ArchiveByteStream.fileStream(
                path: FilePath(archive.path), mode: .readOnly,
                options: [], permissions: FilePermissions(rawValue: 0o644)),
              let decompressed = ArchiveByteStream.decompressionStream(readingFrom: source),
              let decoded = ArchiveStream.decodeStream(readingFrom: decompressed),
              let extraction = ArchiveStream.extractStream(extractingTo: FilePath(directory.path))
        else {
            throw OCRModelInstallError.extractionFailed
        }
        defer {
            try? extraction.close()
            try? decoded.close()
            try? decompressed.close()
            try? source.close()
        }
        do {
            _ = try ArchiveStream.process(readingFrom: decoded, writingTo: extraction)
        } catch {
            throw OCRModelInstallError.extractionFailed
        }
    }

    // MARK: - 编译与落位

    private func compileAndInstall(tier: OCRModelTier, from unpacked: URL) async throws -> InstalledOCRModel {
        let detectorSource = unpacked.appendingPathComponent(OCRModelPack.detectorFileName)
        let recognizerSource = unpacked.appendingPathComponent(OCRModelPack.recognizerFileName)
        let charactersSource = unpacked.appendingPathComponent(OCRModelPack.charactersFileName)
        let fm = FileManager.default
        guard [detectorSource, recognizerSource, charactersSource]
            .allSatisfy({ fm.fileExists(atPath: $0.path) }) else {
            throw OCRModelInstallError.extractionFailed
        }

        // `.mlpackage` 必须先编译成 `.mlmodelc` 才能加载。编译产物与设备/系统版本
        // 绑定，所以只能在设备上做，不能在构建机上预编译好随包下发。
        let compiledDetector: URL
        let compiledRecognizer: URL
        do {
            compiledDetector = try await MLModel.compileModel(at: detectorSource)
            compiledRecognizer = try await MLModel.compileModel(at: recognizerSource)
        } catch {
            throw OCRModelInstallError.compilationFailed
        }

        let root = try OCRModelPack.installDirectory(for: tier)
        // 先落到同级的临时目录再整体改名，避免"装了一半"的目录被 installed() 认成可用。
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent("\(tier.rawValue).staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let target = InstalledOCRModel(
            tier: tier,
            detectorURL: staging.appendingPathComponent(Self.compiledDetector),
            recognizerURL: staging.appendingPathComponent(Self.compiledRecognizer),
            charactersURL: staging.appendingPathComponent(OCRModelPack.charactersFileName)
        )
        do {
            try fm.moveItem(at: compiledDetector, to: target.detectorURL)
            try fm.moveItem(at: compiledRecognizer, to: target.recognizerURL)
            try fm.copyItem(at: charactersSource, to: target.charactersURL)
            var staged = staging
            var values = URLResourceValues()
            // 模型是可重新下载的派生数据，不该占用户的 iCloud 备份额度。
            values.isExcludedFromBackup = true
            try? staged.setResourceValues(values)

            try? fm.removeItem(at: root)
            try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: root)
        } catch {
            try? fm.removeItem(at: staging)
            throw OCRModelInstallError.compilationFailed
        }

        guard let model = installed(tier) else { throw OCRModelInstallError.compilationFailed }
        return model
    }
}
