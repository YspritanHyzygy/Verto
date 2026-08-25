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

import CoreGraphics
import XCTest

@testable import Verto

/// 钉住"识别裁行从原图采样、而不是从检测用的 960 缩略画布采样"。
///
/// 这条曾经是反的：整条识别链路都从画布上裁，12MP 照片先被压掉 4 倍才裁行，
/// 正文笔画在压的那一步就没了，再拉回 48×640 补不出来。这里的测试只要有一条
/// 变回读画布，细节分辨率那条就会立刻红。
final class OCRImageCanvasTests: XCTestCase {

    /// 原图 2400×1800，检测画布 960 → 两轴都是 2.5 倍下采样。
    private let sourceWidth = 2400
    private let sourceHeight = 1800
    private let canvasSide = 960
    private var scale: Double { Double(sourceWidth) / Double(canvasSide) }

    // MARK: - 模型颜色契约

    func testDetectorInputUsesTheV2RGBContract() throws {
        let image = try makeImage { context in
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        }
        let canvas = try XCTUnwrap(OCRImageCanvas(image: image, side: 1))
        var values = [Float](repeating: 0, count: 3)
        values.withUnsafeMutableBufferPointer { destination in
            canvas.fillDetectorInput(
                into: destination.baseAddress!,
                mean: OCRModelPack.correctedDetectorMean,
                std: OCRModelPack.correctedDetectorStd
            )
        }

        XCTAssertEqual(values[0], (1 - 0.406) / 0.225, accuracy: 0.001)
        XCTAssertEqual(values[1], (0 - 0.456) / 0.224, accuracy: 0.001)
        XCTAssertEqual(values[2], (0 - 0.485) / 0.229, accuracy: 0.001)
    }

    func testRecognizerInputKeepsRGBPlaneOrder() {
        let crop = OCRLineCrop(
            width: 1, height: 1, usedWidth: 1,
            pixels: [255, 0, 0]
        )
        var values = [Float](repeating: 0, count: 3)
        values.withUnsafeMutableBufferPointer { destination in
            crop.fillRecognizerInput(into: destination.baseAddress!)
        }

        XCTAssertEqual(values, [1, -1, -1])
    }

    // MARK: - 分辨率

    func testCropKeepsDetailThatTheDetectionCanvasWouldHaveAveragedAway() throws {
        // 2px 黑 / 2px 白的竖条纹，周期 4 个原图像素。
        // 缩到画布上周期只剩 1.6 像素，`interpolationQuality = .high` 会把它
        // 均匀抹成中灰——**画布上这块区域的明暗差接近 0**。
        // 只有真的回原图采样，条纹才还在。
        let image = try makeImage { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
            context.setFillColor(gray: 0, alpha: 1)
            for x in stride(from: 0, to: sourceWidth, by: 4) {
                context.fill(CGRect(x: x, y: 0, width: 2, height: sourceHeight))
            }
        }
        let canvas = try XCTUnwrap(OCRImageCanvas(image: image, side: canvasSide))

        // 画布坐标下 100×50 的框：换算到原图是 250×125，横向采样约 1.3 像素一个点，
        // 足够分辨 4 像素的周期。
        let crop = try XCTUnwrap(canvas.crop(canvasBox(x: 400, y: 300, width: 100, height: 50)))
        let values = normalizedValues(of: crop)
        let brightest = try XCTUnwrap(values.max())
        let darkest = try XCTUnwrap(values.min())
        let spread = brightest - darkest

        // 归一化后取值域是 [-1, 1]，纯黑白条纹的跨度应该接近 2。
        // 从画布采样的话这里会塌到 0.2 以下。
        XCTAssertGreaterThan(
            spread, 1.2,
            "细条纹被抹平了，说明裁行又是从 960 画布上采的样，而不是原图"
        )
    }

    // MARK: - 坐标

    func testCropMapsCanvasCoordinatesOntoTheOriginalWithoutFlippingY() throws {
        // 上半黑、下半白。CGContext 原点在左下，所以先画的那半在图像**下方**。
        let image = try makeImage { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight / 2))
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: sourceHeight / 2, width: sourceWidth, height: sourceHeight / 2))
        }
        let canvas = try XCTUnwrap(OCRImageCanvas(image: image, side: canvasSide))

        // 画布坐标原点左上、y 向下：小 y 是图像顶部（黑），大 y 是底部（白）。
        let top = try XCTUnwrap(canvas.crop(canvasBox(x: 300, y: 80, width: 200, height: 40)))
        let bottom = try XCTUnwrap(canvas.crop(canvasBox(x: 300, y: 600, width: 200, height: 40)))

        XCTAssertLessThan(mean(of: top), -0.8, "画布上方应落在原图黑色那半；翻 y 了")
        XCTAssertGreaterThan(mean(of: bottom), 0.8, "画布下方应落在原图白色那半；翻 y 了")
    }

    func testCropMapsCanvasXOntoTheOriginalAtTheRightScale() throws {
        // 只有原图右侧四分之一是黑的。画布上对应 x > 720。
        let image = try makeImage { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: sourceWidth * 3 / 4, y: 0,
                                width: sourceWidth / 4, height: sourceHeight))
        }
        let canvas = try XCTUnwrap(OCRImageCanvas(image: image, side: canvasSide))

        let left = try XCTUnwrap(canvas.crop(canvasBox(x: 100, y: 300, width: 200, height: 40)))
        let right = try XCTUnwrap(canvas.crop(canvasBox(x: 760, y: 300, width: 180, height: 40)))

        XCTAssertGreaterThan(mean(of: left), 0.8, "画布左侧应落在原图白色区")
        XCTAssertLessThan(mean(of: right), -0.8, "画布右侧应落在原图黑色区；x 的缩放比例错了")
    }

    // MARK: - 边界

    func testCropRejectsDegenerateBoxes() throws {
        let image = try makeImage { context in
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        }
        let canvas = try XCTUnwrap(OCRImageCanvas(image: image, side: canvasSide))

        XCTAssertNil(canvas.crop([]), "角点数不对应该拒绝")
        XCTAssertNil(canvas.crop(canvasBox(x: 10, y: 10, width: 0, height: 40)), "零宽框应该拒绝")
        XCTAssertNil(canvas.crop(canvasBox(x: 10, y: 10, width: 40, height: 0)), "零高框应该拒绝")
    }

    func testCropSurvivesBoxesRunningOffTheEdge() throws {
        // 贴着右下角、且越界的框：LinePatch 会和原图边界求交，不能因此返回 nil 或崩。
        let image = try makeImage { context in
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        }
        let canvas = try XCTUnwrap(OCRImageCanvas(image: image, side: canvasSide))

        let crop = try XCTUnwrap(
            canvas.crop(canvasBox(x: 900, y: 680, width: 200, height: 80)),
            "越界框应该被钳到图内，而不是整行丢掉"
        )
        XCTAssertLessThan(mean(of: crop), -0.8, "钳制后仍应采到黑色")
    }

    // MARK: - 工具

    /// 轴对齐框的四角，顺序与 `TextDetectionPostProcess.RotatedBox` 一致：
    /// 左上、右上、右下、左下。坐标是画布像素（原点左上、y 向下）。
    private func canvasBox(x: Double, y: Double, width: Double, height: Double) -> [CGPoint] {
        [
            CGPoint(x: x, y: y),
            CGPoint(x: x + width, y: y),
            CGPoint(x: x + width, y: y + height),
            CGPoint(x: x, y: y + height),
        ]
    }

    private func makeImage(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: sourceWidth, height: sourceHeight,
            bitsPerComponent: 8, bytesPerRow: sourceWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .high
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    /// 走 `fillRecognizerInput` 读裁片——那是它唯一的对外出口，
    /// 顺带把归一化也一起验了。只取有内容的那部分，右侧补白不算。
    private func normalizedValues(of crop: OCRLineCrop) -> [Float] {
        let plane = crop.height * crop.width
        var buffer = [Float](repeating: 0, count: plane * 3)
        buffer.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            crop.fillRecognizerInput(into: base)
        }
        // 只读绿通道的有效区：灰阶图三通道相同，取一个就够。
        var values: [Float] = []
        values.reserveCapacity(crop.height * crop.usedWidth)
        for y in 0..<crop.height {
            for x in 0..<crop.usedWidth {
                values.append(buffer[plane + y * crop.width + x])
            }
        }
        return values
    }

    private func mean(of crop: OCRLineCrop) -> Float {
        let values = normalizedValues(of: crop)
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }
}
