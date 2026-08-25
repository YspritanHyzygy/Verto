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
import UIKit
import XCTest
@testable import Verto

final class OCRModelPackMetadataTests: XCTestCase {
    func testPublishedReleaseContract() throws {
        let expected: [OCRModelTier: (name: String, bytes: Int64, sha256: String)] = [
            .tiny: (
                "pp-ocr-v6-coreml-tiny-v1.aar", 2_915_454,
                "c0eba9a3affa1f2a5591e07739d9ca861d9f9417bf0258e56c1b06e9299a1aba"
            ),
            .small: (
                "pp-ocr-v6-coreml-small-v1.aar", 12_999_796,
                "8f32f551fdddd7cb136ce54e7566aa453e1ca6f7c1f6a6ae7d1f75de1addfe10"
            ),
            .medium: (
                "pp-ocr-v6-coreml-medium-v1.aar", 47_521_629,
                "960ed7c0065e3d21d1b52cc1a0ae3fb1b28911d5735f455cc82483009c3128be"
            ),
        ]

        XCTAssertEqual(OCRModelPack.version, "1")
        XCTAssertEqual(OCRModelPack.detectorMean, [0.485, 0.456, 0.406])
        XCTAssertTrue(OCRModelTier.allCases.allSatisfy { $0.boxScoreThreshold == 0.45 })
        for tier in OCRModelTier.allCases {
            let contract = try XCTUnwrap(expected[tier])
            XCTAssertEqual(tier.archiveName, contract.name)
            XCTAssertEqual(tier.downloadBytes, contract.bytes)
            XCTAssertEqual(tier.sha256, contract.sha256)
            XCTAssertEqual(
                tier.archiveURL.absoluteString,
                "https://github.com/YspritanHyzygy/PP-OCR-for-Apple/releases/download/v1/\(contract.name)"
            )
        }
    }

    func testInstalledV1DirectoryDoesNotDependOnRemoteAssetName() throws {
        let directory = try OCRModelPack.installDirectory(for: .small)
        XCTAssertTrue(directory.path.hasSuffix("/OCRModels/v1/small"))
        XCTAssertFalse(directory.path.contains("pp-ocr-v6-coreml"))
    }

    func testArchiveChecksumRejectsCorruption() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-checksum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data("abc".utf8).write(to: archive)

        XCTAssertNoThrow(try OCRModelPackInstaller.verifyChecksum(
            of: archive,
            expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        ))
        XCTAssertThrowsError(try OCRModelPackInstaller.verifyChecksum(
            of: archive, expected: String(repeating: "0", count: 64)
        )) { error in
            XCTAssertEqual(error as? OCRModelInstallError, .checksumMismatch)
        }
    }

    func testActivationReplacesACompleteDirectoryAsOneUnit() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-activation-\(UUID().uuidString)", isDirectory: true)
        let installed = parent.appendingPathComponent("small", isDirectory: true)
        let staging = parent.appendingPathComponent("small.staging", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("marker"))

        try OCRModelPackInstaller.activate(staging: staging, at: installed)

        XCTAssertEqual(
            try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8),
            "new"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testV1CodeDoesNotDeleteItsOwnInstallDirectory() throws {
        XCTAssertNil(try OCRModelPack.obsoleteV1InstallDirectory(for: .small))
    }
}

/// 诊断探针：拿**真实的** Core ML 模型端到端跑一遍高精度识别管线。
///
/// 存在的理由：检测后处理（连通域/凸包/旋转卡壳/unclip）、旋转裁切和 CTC 解码
/// 加起来约 600 行是重写的，几何写错不会崩、只会安静地给出错结果。
/// 单测能覆盖纯函数，但"这一整条链路接起来还是同一个 OCR"只有真模型能回答。
///
/// 模型不在仓库里（14MB~47MB，由 PP-OCR-for-Apple Release 分发），所以用环境变量指路：
///     VERTO_OCR_MODEL_DIR=/private/tmp/pp-ocr-for-apple/out/small
///     VERTO_OCR_MODEL_TIER=small
/// 没设就跳过并说明原因，不伪装成通过。
final class PaddleOCRProbeTests: XCTestCase {
    /// 探针图上的原文，由测试自己画上去，不是 app 里的演示数据。
    private static let lines = ["欢迎光临", "营业时间 09:00-21:00", "禁止吸烟"]

    private static let reportPath = "/private/tmp/paddle-ocr-probe.txt"

    private struct Corpus: Decodable {
        let schemaVersion: Int
        let samples: [CorpusSample]
    }

    private struct CorpusSample: Decodable {
        let id: String
        let dataset: String
        let language: String
        let scenario: String
        let evaluationTask: String?
        let imagePath: String
        let groundTruth: [CorpusLine]
    }

    private struct CorpusLine: Codable {
        let polygon: [[Double]]
        let text: String
        let ignore: Bool?
    }

    private struct OutputSample: Encodable {
        let id: String
        let dataset: String
        let language: String
        let scenario: String
        let evaluationTask: String?
        let groundTruth: [CorpusLine]
        let detectionPredictions: [CorpusLine]
        let predictions: [CorpusLine]
        let timingsMilliseconds: [String: Double]
    }

    private struct BenchmarkReport: Encodable {
        struct Run: Encodable {
            let tier: String
            let device: String
            let systemVersion: String
            let operatingSystem: String
            let computeUnits: String
            let warmupRuns: Int
            let coldCompileMilliseconds: Double
            let coldLoadMilliseconds: Double
        }

        let schemaVersion: Int
        let run: Run
        let samples: [OutputSample]
    }

    func testProbePaddleRecognitionPipeline() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VERTO_OCR_MODEL_DIR"] else {
            throw XCTSkip("""
                未设置 VERTO_OCR_MODEL_DIR，跳过真实模型探针。
                先在 PP-OCR-for-Apple 仓库运行 scripts/build_models.py，再把某一档目录指过来。
                """)
        }
        let root = URL(fileURLWithPath: directory)
        let tier = try Self.modelTier()
        var report: [String] = ["MODEL_DIR: \(directory)", "MODEL_TIER: \(tier.rawValue)"]
        // 每一步都先落盘再往下走：探针的价值一半在于失败时告诉你卡在哪，
        // 只在成功路径末尾写报告的话，一旦中途抛错就什么线索都没有。
        defer { Self.write(report) }

        for name in [OCRModelPack.detectorFileName, OCRModelPack.recognizerFileName,
                     OCRModelPack.charactersFileName] {
            let path = root.appendingPathComponent(name).path
            report.append("exists(\(name)) = \(FileManager.default.fileExists(atPath: path))")
        }

        let model: InstalledOCRModel
        do {
            model = try await Self.compile(from: root, tier: tier)
        } catch {
            report.append("compileModel 抛错: \(error)")
            throw error
        }
        report.append("compiled: detector=\(model.detectorURL.lastPathComponent) "
                      + "recognizer=\(model.recognizerURL.lastPathComponent)")

        let service: PaddleTextRecognitionService
        do {
            service = try PaddleTextRecognitionService(model: model)
        } catch {
            report.append("加载模型/字表抛错: \(error)")
            throw error
        }
        let image = try XCTUnwrap(Self.renderSign().normalizedUp().cgImage)

        let started = Date()
        let blocks: [RecognizedTextBlock]
        do {
            blocks = try await service.recognizeText(in: image, languages: [.chinese])
        } catch {
            report.append("recognizeText 抛错: \(error)")
            throw error
        }
        report.append(String(format: "recognize: %d blocks in %.0f ms",
                             blocks.count, Date().timeIntervalSince(started) * 1000))
        for block in blocks {
            let box = block.quad.boundingBox
            report.append(String(format: "  %@ | conf=%.2f lines=%d box=(%.3f,%.3f,%.3f,%.3f)",
                                 block.text, block.confidence, block.lineCount,
                                 box.minX, box.minY, box.width, box.height))
        }

        // 逐行核对：每行的字都要出现在识别结果里。
        let joined = blocks.map(\.text).joined()
        for line in Self.lines {
            let core = line.replacingOccurrences(of: " ", with: "")
            XCTAssertTrue(
                core.allSatisfy { joined.contains($0) },
                "「\(line)」没有被完整识别出来。实际：\(blocks.map(\.text))\n\(report.joined(separator: "\n"))"
            )
        }

        // 位置也要对：Vision 归一化坐标 y 轴向上，画在上方的「欢迎光临」应有更大的 y。
        // 这一条专门盯 DB 后处理里的 y 轴翻转——翻反了文字仍然识别得出来，
        // 但叠加层会把所有译文上下颠倒地贴回照片上。
        let welcome = try XCTUnwrap(blocks.first { $0.text.contains("欢迎") })
        let noSmoking = try XCTUnwrap(blocks.first { $0.text.contains("吸烟") })
        XCTAssertGreaterThan(welcome.quad.boundingBox.midY, noSmoking.quad.boundingBox.midY,
                             "顶部那行的归一化 y 应大于底部那行")

        // 框要贴合文字，不能是覆盖全图的巨框——unclip 写错时最典型的症状。
        for block in blocks {
            XCTAssertLessThan(block.quad.boundingBox.height, 0.5,
                              "单行文字框高度占了半张图，说明连通域或 unclip 有问题：\(block.text)")
        }
    }

    /// 用真实生产链路输出公开评测器需要的原始行、框和耗时。这里不做匹配、CER、
    /// bootstrap 或 pass/fail 判定；分数统一由 PP-OCR-for-Apple 的评测脚本计算。
    func testBenchmarkExternalCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelDirectory = environment["VERTO_OCR_MODEL_DIR"],
              let corpusPath = environment["VERTO_OCR_CORPUS_JSON"],
              let outputPath = environment["VERTO_OCR_REPORT_PATH"] else {
            throw XCTSkip("未同时设置模型目录、语料 JSON 和原始报告路径，跳过真实语料 benchmark")
        }

        let tier = try Self.modelTier()
        let corpusURL = URL(fileURLWithPath: corpusPath)
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertFalse(corpus.samples.isEmpty)

        let compileStarted = Date()
        let model = try await Self.compile(
            from: URL(fileURLWithPath: modelDirectory), tier: tier
        )
        let coldCompileMilliseconds = Date().timeIntervalSince(compileStarted) * 1000
        let loadStarted = Date()
        let service = try PaddleTextRecognitionService(model: model)
        let coldLoadMilliseconds = Date().timeIntervalSince(loadStarted) * 1000
        let resolved = try corpus.samples.map { sample -> (CorpusSample, CGImage) in
            let language = try XCTUnwrap(
                Language.all.first { $0.code == sample.language },
                "语料包含 Verto 不认识的语言代码：\(sample.language)"
            )
            XCTAssertTrue(
                tier.recognizes(language),
                "\(tier.rawValue) 不覆盖 \(sample.language)，不能把 Vision 回退混进模型 benchmark"
            )
            return (sample, try Self.loadImage(sample.imagePath, relativeTo: corpusURL))
        }

        let warmupRuns = Int(environment["VERTO_OCR_WARMUP_RUNS"] ?? "3") ?? 3
        if let first = resolved.first {
            for _ in 0..<max(0, warmupRuns) {
                _ = try? await service.recognizeLines(in: first.1)
            }
        }

        var outputs: [OutputSample] = []
        for (sample, image) in resolved {
            let started = Date()
            let pipeline = try await service.runPipeline(
                in: image,
                collectTimings: true,
                recognizeText: sample.evaluationTask != "detection"
            )
            let elapsed = Date().timeIntervalSince(started) * 1000
            var timings = pipeline.timingsMilliseconds
            timings["endToEnd"] = elapsed
            outputs.append(OutputSample(
                id: sample.id,
                dataset: sample.dataset,
                language: sample.language,
                scenario: sample.scenario,
                evaluationTask: sample.evaluationTask,
                groundTruth: sample.groundTruth,
                detectionPredictions: pipeline.detectionQuads.map {
                    Self.corpusLine(from: $0, text: "", image: image)
                },
                predictions: pipeline.lines.map { Self.corpusLine(from: $0, image: image) },
                timingsMilliseconds: timings
            ))
        }

        let device = await MainActor.run {
            (model: UIDevice.current.model, systemVersion: UIDevice.current.systemVersion)
        }
        let report = BenchmarkReport(
            schemaVersion: 1,
            run: .init(
                tier: tier.rawValue,
                device: device.model,
                systemVersion: device.systemVersion,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                computeUnits: "ALL",
                warmupRuns: max(0, warmupRuns),
                coldCompileMilliseconds: coldCompileMilliseconds,
                coldLoadMilliseconds: coldLoadMilliseconds
            ),
            samples: outputs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: URL(fileURLWithPath: outputPath), options: .atomic
        )
    }

    /// 韩语没有谚文字表，必须仍然由系统引擎接管，不能悄悄用高精度模型识别成乱码。
    func testKoreanIsRoutedToSystemEngineOnEveryTier() throws {
        let korean = try XCTUnwrap(Language.all.first { $0.code == "ko" })
        for tier in OCRModelTier.allCases {
            XCTAssertFalse(
                RoutingTextRecognitionService.canUseHighAccuracy(tier: tier, languages: [korean]),
                "\(tier.rawValue) 档不该接手韩语——PP-OCRv6 字表里没有谚文"
            )
        }
        // 德语在三档都该走高精度模型。
        let german = try XCTUnwrap(Language.all.first { $0.code == "de" })
        for tier in OCRModelTier.allCases {
            XCTAssertTrue(RoutingTextRecognitionService.canUseHighAccuracy(tier: tier, languages: [german]))
        }
        // 日文只有 tiny 档缺假名。
        XCTAssertFalse(RoutingTextRecognitionService.canUseHighAccuracy(tier: .tiny, languages: [.japanese]))
        XCTAssertTrue(RoutingTextRecognitionService.canUseHighAccuracy(tier: .small, languages: [.japanese]))
        // 自动检测时画面里可能是任何文字，不能赌。
        XCTAssertFalse(RoutingTextRecognitionService.canUseHighAccuracy(tier: .medium, languages: []))
    }

    /// 读取模型输出时必须走 `strides`，不能把缓冲当连续行优先。
    ///
    /// 这条规则只在**有神经引擎的真机**上会被违反：ANE 把识别模型输出的类别维
    /// 从 18710 补齐到 18720，而 CPU/GPU 上恰好是连续的。所以模拟器上跑真模型
    /// 永远测不出来，必须手工造一个带补齐步长的张量把规则钉死。
    /// 违反时的症状是识别结果变成散落在字表各处的乱码——真机上出现过。
    func testDenseFloatsRespectsPaddedStrides() throws {
        let rows = 3, used = 5, padded = 8      // 每行 5 个有效值，补齐到 8
        let sentinel: Float = -999              // 落进补齐区就会读到它
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: rows * padded)
        defer { storage.deallocate() }
        for r in 0..<rows {
            for c in 0..<padded {
                storage[r * padded + c] = c < used ? Float(r * 10 + c) : sentinel
            }
        }

        let array = try MLMultiArray(
            dataPointer: storage,
            shape: [1, NSNumber(value: rows), NSNumber(value: used)],
            dataType: .float32,
            strides: [NSNumber(value: rows * padded), NSNumber(value: padded), 1]
        )

        let dense = try PaddleTextRecognitionService.denseFloats(from: array)
        XCTAssertEqual(dense, [0, 1, 2, 3, 4, 10, 11, 12, 13, 14, 20, 21, 22, 23, 24],
                       "补齐步长没被尊重——按连续布局读会把后面每一行都读偏")
        XCTAssertFalse(dense.contains(sentinel), "读到了补齐区的填充值")
    }

    // MARK: - 辅助

    private static func modelTier() throws -> OCRModelTier {
        let value = ProcessInfo.processInfo.environment["VERTO_OCR_MODEL_TIER"] ?? "small"
        return try XCTUnwrap(OCRModelTier(rawValue: value), "无效的 VERTO_OCR_MODEL_TIER：\(value)")
    }

    private static func compile(from root: URL, tier: OCRModelTier) async throws -> InstalledOCRModel {
        let environment = ProcessInfo.processInfo.environment
        let detectorSize = Int(environment["VERTO_OCR_DETECTOR_SIZE"] ?? "")
            ?? OCRModelPack.detectorInputSize
        let recognizerWidth = Int(environment["VERTO_OCR_RECOGNIZER_WIDTH"] ?? "")
            ?? OCRModelPack.recognizerInputWidth
        let usesB0ColorContract = environment["VERTO_OCR_B0_COLOR_CONTRACT"] == "1"
        let threshold = Float(environment["VERTO_OCR_BOX_SCORE_THRESHOLD"] ?? "")
        let detector = try await MLModel.compileModel(
            at: root.appendingPathComponent(OCRModelPack.detectorFileName))
        let recognizer = try await MLModel.compileModel(
            at: root.appendingPathComponent(OCRModelPack.recognizerFileName))
        return InstalledOCRModel(
            tier: tier,
            detectorURL: detector,
            recognizerURL: recognizer,
            charactersURL: root.appendingPathComponent(OCRModelPack.charactersFileName),
            detectorInputSize: detectorSize,
            recognizerInputWidth: recognizerWidth,
            detectorMean: usesB0ColorContract
                ? [0.485, 0.456, 0.406] : OCRModelPack.correctedDetectorMean,
            detectorStd: usesB0ColorContract
                ? [0.229, 0.224, 0.225] : OCRModelPack.correctedDetectorStd,
            boxScoreThreshold: threshold
                ?? (usesB0ColorContract ? 0.45 : tier.correctedBoxScoreThreshold)
        )
    }

    private static func loadImage(_ path: String, relativeTo corpusURL: URL) throws -> CGImage {
        let resolved = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : corpusURL.deletingLastPathComponent().appendingPathComponent(path)
        let image = try XCTUnwrap(UIImage(contentsOfFile: resolved.path), "读不到语料图片：\(resolved.path)")
        return try XCTUnwrap(image.normalizedUp().cgImage, "语料图片无法转成 CGImage：\(resolved.path)")
    }

    private static func corpusLine(
        from block: RecognizedTextBlock,
        image: CGImage
    ) -> CorpusLine {
        corpusLine(from: block.quad, text: block.text, image: image)
    }

    private static func corpusLine(
        from quad: TextQuad,
        text: String,
        image: CGImage
    ) -> CorpusLine {
        func pixel(_ point: CGPoint) -> [Double] {
            [Double(point.x) * Double(image.width),
             (1 - Double(point.y)) * Double(image.height)]
        }
        return CorpusLine(
            polygon: [
                pixel(quad.topLeft),
                pixel(quad.topRight),
                pixel(quad.bottomRight),
                pixel(quad.bottomLeft),
            ],
            text: text,
            ignore: nil
        )
    }

    /// 与 `VisionAvailabilityProbeTests` 用同一张告示，方便两个引擎横向对照。
    private static func renderSign() -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [
                UIColor(red: 0.95, green: 0.92, blue: 0.85, alpha: 1).cgColor,
                UIColor(red: 0.88, green: 0.84, blue: 0.75, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero,
                    end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let ink = UIColor(red: 0.13, green: 0.12, blue: 0.10, alpha: 1)
            let frames: [CGRect] = [
                CGRect(x: 126, y: 270, width: 470, height: 90),
                CGRect(x: 126, y: 420, width: 650, height: 54),
                CGRect(x: 126, y: 780, width: 360, height: 66)
            ]
            for (line, frame) in zip(lines, frames) {
                (line as NSString).draw(in: frame, withAttributes: [
                    .font: UIFont.systemFont(ofSize: frame.height * 0.85, weight: .semibold),
                    .foregroundColor: ink
                ])
            }
        }
    }

    private static func write(_ report: [String]) {
        // 测试里的 print 不进 xcodebuild 输出，落盘才看得到。
        try? (report.joined(separator: "\n") + "\n")
            .write(toFile: reportPath, atomically: true, encoding: .utf8)
    }
}
