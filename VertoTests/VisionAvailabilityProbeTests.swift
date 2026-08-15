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

import UIKit
import Vision
import XCTest
@testable import Verto

/// 诊断探针：报告当前运行环境下 Vision 文字识别的真实可用性，并把**真实的**
/// `VisionTextRecognitionService` 跑在一张现画的中文告示上端到端验一遍。
///
/// 存在的理由：UI 测试全程走罐头识别与罐头译文（`--uitest-canned-*`），
/// 那条路一行 Vision 代码都不碰。没有这个探针，"端侧 OCR 真能用"就只是推断。
/// 报告落盘 /private/tmp/vision-availability-probe.txt，与语音探针同一套做法。
final class VisionAvailabilityProbeTests: XCTestCase {
    /// 探针图上的原文。这是**测试自己画上去的输入**，不是 app 里的演示数据，
    /// 所以断言识别结果等于它是在验识别，不是把假数据钉成规格。
    private static let lines = ["欢迎光临", "营业时间 09:00-21:00", "禁止吸烟"]

    func testProbeVisionTextRecognition() async throws {
        var report: [String] = []
#if targetEnvironment(simulator)
        report.append("ENV: simulator")
#else
        report.append("ENV: device")
#endif

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        report.append("VNRecognizeTextRequest.revision = \(request.revision)")
        report.append("supportedRecognitionLanguages(\(supported.count)) = \(supported.sorted().joined(separator: ","))")
        for language in Language.all {
            let code = language.visionRecognitionLanguage
            report.append("  \(language.code) -> \(code): supported=\(supported.contains(code))")
        }

        let image = Self.renderSign()
        let cgImage = try XCTUnwrap(image.normalizedUp().cgImage)
        let service = VisionTextRecognitionService()

        var recognized: [RecognizedTextBlock] = []
        var failure: String?
        do {
            recognized = try await service.recognizeText(in: cgImage, languages: [.chinese])
        } catch {
            failure = "\(error)"
        }
        report.append("recognize(zh-Hans): blocks=\(recognized.count) error=\(failure ?? "nil")")
        for block in recognized {
            let box = block.quad.boundingBox
            report.append(String(
                format: "  %@ | conf=%.2f lines=%d box=(%.3f,%.3f,%.3f,%.3f)",
                block.text, block.confidence, block.lineCount,
                box.minX, box.minY, box.width, box.height
            ))
        }
        Self.write(report)

        // 识别不可用时明确失败并附报告，不静默放过——这正是探针要回答的问题。
        XCTAssertNil(failure, "Vision 文字识别在本环境不可用：\(failure ?? "")\n\(report.joined(separator: "\n"))")
        let joined = recognized.map(\.text).joined()
        for line in Self.lines {
            // 逐行核对：只要每行的字都出现在识别结果里，就说明中文 OCR 真的通了。
            let core = line.replacingOccurrences(of: " ", with: "")
            XCTAssertTrue(
                core.allSatisfy { joined.contains($0) },
                "「\(line)」没有被完整识别出来。实际结果：\(recognized.map(\.text))"
            )
        }

        // 位置也要对：Vision 坐标原点在左下，画在上方的「欢迎光临」应有最大的 y。
        let welcome = try XCTUnwrap(recognized.first { $0.text.contains("欢迎") })
        let noSmoking = try XCTUnwrap(recognized.first { $0.text.contains("吸烟") })
        XCTAssertGreaterThan(
            welcome.quad.boundingBox.midY,
            noSmoking.quad.boundingBox.midY,
            "顶部那行的归一化 y 应大于底部那行（Vision y 轴向上）"
        )

        // 分段要对：标题「欢迎光临」与其下的正文字号差 1.7 倍，属于不同层级，
        // 不许并成一段——只按间距分段时它们正是被并起来的（本探针抓到过）。
        XCTAssertFalse(
            welcome.text.contains("营业时间"),
            "标题被并进了正文块：\(welcome.text)"
        )
    }

    /// 画一张"照片感"的告示：暖底 + 轻微渐变，深色字，避免纯白纯黑这种
    /// 与真实拍摄相去甚远的极端条件。
    private static func renderSign() -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [
                UIColor(red: 0.95, green: 0.92, blue: 0.85, alpha: 1).cgColor,
                UIColor(red: 0.88, green: 0.84, blue: 0.75, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
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
        let text = report.joined(separator: "\n") + "\n"
        // 测试里的 print 不进 xcodebuild 输出，落盘才看得到（模拟器与宿主共享文件系统）。
        try? text.write(
            toFile: "/private/tmp/vision-availability-probe.txt",
            atomically: true,
            encoding: .utf8
        )
    }
}
