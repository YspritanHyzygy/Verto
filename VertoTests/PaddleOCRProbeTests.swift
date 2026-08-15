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

/// 诊断探针：拿**真实的** Core ML 模型端到端跑一遍高精度识别管线。
///
/// 存在的理由：检测后处理（连通域/凸包/旋转卡壳/unclip）、旋转裁切和 CTC 解码
/// 加起来约 600 行是重写的，几何写错不会崩、只会安静地给出错结果。
/// 单测能覆盖纯函数，但"这一整条链路接起来还是同一个 OCR"只有真模型能回答。
///
/// 模型不在仓库里（14MB~47MB，由 GitHub Release 分发），所以用环境变量指路：
///     VERTO_OCR_MODEL_DIR=/private/tmp/verto-ocr-build/out/small
/// 没设就跳过并说明原因，不伪装成通过。
final class PaddleOCRProbeTests: XCTestCase {
    /// 探针图上的原文，由测试自己画上去，不是 app 里的演示数据。
    private static let lines = ["欢迎光临", "营业时间 09:00-21:00", "禁止吸烟"]

    private static let reportPath = "/private/tmp/paddle-ocr-probe.txt"

    func testProbePaddleRecognitionPipeline() async throws {
        guard let directory = ProcessInfo.processInfo.environment["VERTO_OCR_MODEL_DIR"] else {
            throw XCTSkip("""
                未设置 VERTO_OCR_MODEL_DIR，跳过真实模型探针。
                先跑 tools/build-ocr-models/build_models.py 产出模型，再把某一档目录指过来。
                """)
        }
        let root = URL(fileURLWithPath: directory)
        var report: [String] = ["MODEL_DIR: \(directory)"]
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
            model = try await Self.compile(from: root)
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

    private static func compile(from root: URL) async throws -> InstalledOCRModel {
        let detector = try await MLModel.compileModel(
            at: root.appendingPathComponent(OCRModelPack.detectorFileName))
        let recognizer = try await MLModel.compileModel(
            at: root.appendingPathComponent(OCRModelPack.recognizerFileName))
        return InstalledOCRModel(
            tier: .small,
            detectorURL: detector,
            recognizerURL: recognizer,
            charactersURL: root.appendingPathComponent(OCRModelPack.charactersFileName)
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
