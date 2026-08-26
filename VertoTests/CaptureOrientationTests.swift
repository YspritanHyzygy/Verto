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

/// 横持拍照这条路上的方向换算。
///
/// 产品上的约定是"照片一个像素不改"：倒着拍就得到倒着的照片，取景器里什么构图、
/// 结果页就什么构图。歪只歪在送去识别的那份副本里——转正、识别、把框转回来。
///
/// 于是正确性完全落在两个纯函数上，而它们错了在截图上很难分辨：译框整体转 90°
/// 落到别处，看起来和"识别本身不准"一模一样。所以这里逐条钉死。
final class CaptureOrientationTests: XCTestCase {

    // MARK: - 读数 → 圈数

    /// 竖持：系统建议的角度正好就是我们固定用的角度，画面不歪。
    func testPortraitCaptureNeedsNoStraightening() {
        XCTAssertEqual(snapshot(applied: 90, level: 90).contentQuarterTurns, 0)
    }

    /// 真机实测的那一组（iPhone 16 Pro 横持）：读数 90/0，出图里的印刷字从上往下跑、
    /// 字头朝左——要逆时针转 90° 才正，也就是画面顺时针歪了一格。
    func testLandscapeCaptureIsOneClockwiseQuarterTurn() {
        XCTAssertEqual(snapshot(applied: 90, level: 0).contentQuarterTurns, 1)
    }

    /// 另一种横持必须歪向反面，否则两种横持会被同一个修正一起弄错一个。
    func testOppositeLandscapeIsThreeClockwiseQuarterTurns() {
        XCTAssertEqual(snapshot(applied: 90, level: 180).contentQuarterTurns, 3)
    }

    func testUpsideDownIsHalfTurn() {
        XCTAssertEqual(snapshot(applied: 90, level: 270).contentQuarterTurns, 2)
    }

    /// 读不到重力（模拟器、协调器还没起来）就当正立——退回加这套东西之前的行为，
    /// 而不是拿一个瞎猜的角度把竖屏也弄歪。
    func testMissingReadingFallsBackToUpright() {
        XCTAssertEqual(snapshot(applied: nil, level: 0).contentQuarterTurns, 0)
        XCTAssertEqual(snapshot(applied: 90, level: nil).contentQuarterTurns, 0)
    }

    // MARK: - 归一化坐标转回去

    /// Vision 的 y 向上，y=1 是画面视觉上的顶边——所以"顺时针"和肉眼看到的一致：
    /// 左上角转到右上角。
    func testClockwiseQuarterTurnSendsImageTopLeftToTopRight() {
        let corner = TextQuad.upright(x: 0, y: 1, width: 0, height: 0)

        let turned = corner.rotatedClockwise(quarterTurns: 1)

        XCTAssertEqual(turned.topLeft.x, 1, accuracy: 1e-9)
        XCTAssertEqual(turned.topLeft.y, 1, accuracy: 1e-9)
    }

    func testFourQuarterTurnsAreIdentity() {
        let quad = TextQuad.upright(x: 0.2, y: 0.5, width: 0.4, height: 0.1)

        XCTAssertEqual(quad.rotatedClockwise(quarterTurns: 4), quad)
        XCTAssertEqual(quad.rotatedClockwise(quarterTurns: 0), quad)
        XCTAssertEqual(quad.rotatedClockwise(quarterTurns: -4), quad)
    }

    /// 转回去之后行高与行长不能变，倾角要跟着躺下来——贴纸的旋转、字号与折行
    /// 全从这三个量推出来。四角的名字若跟着转，倾角会被抹平成 0，字就贴不歪了。
    func testRotationKeepsLineMetricsAndTiltsTheBaseline() {
        let line = TextQuad.upright(x: 0.1, y: 0.6, width: 0.5, height: 0.05)

        let turned = line.rotatedClockwise(quarterTurns: 1)

        XCTAssertEqual(turned.baselineLength, 0.5, accuracy: 1e-9)
        XCTAssertEqual(turned.uprightHeight, 0.05, accuracy: 1e-9)
        XCTAssertEqual(turned.angle, -.pi / 2, accuracy: 1e-9)
    }

    // MARK: - 像素转正

    func testStraighteningZeroTurnsHandsBackTheSameImage() {
        let image = markedImage(width: 4, height: 2, markerX: 0, markerY: 0)

        XCTAssertTrue(OCRImageStraightening.straighten(image, quarterTurnsClockwise: 0) === image)
    }

    /// 画面顺时针歪了一格，就要逆时针转回去：长宽互换，左上角的标记落到左下角。
    /// 方向错了会转成 180°，横屏两种持法各错 90°。
    func testStraighteningOneQuarterTurnRotatesCounterClockwise() {
        let image = markedImage(width: 4, height: 2, markerX: 0, markerY: 0)

        let straightened = OCRImageStraightening.straighten(image, quarterTurnsClockwise: 1)

        XCTAssertEqual(straightened.width, 2)
        XCTAssertEqual(straightened.height, 4)
        XCTAssertEqual(markerPosition(in: straightened), Marker(x: 0, y: 3))
    }

    // MARK: - 两者互为逆运算

    /// 真正要守的不变量：在转正后的图里量到的框，转回去必须落回原图上同一块像素。
    /// 两个方向只要有一个符号错了，这条就过不去。
    func testStraightenAndRotateBackLandOnTheSamePixels() {
        let width = 5
        let height = 3
        for turns in 0..<4 {
            for marker in [Marker(x: 0, y: 0), Marker(x: 4, y: 0), Marker(x: 1, y: 2)] {
                let original = markedImage(
                    width: width,
                    height: height,
                    markerX: marker.x,
                    markerY: marker.y
                )
                let straightened = OCRImageStraightening.straighten(
                    original,
                    quarterTurnsClockwise: turns
                )
                guard let found = markerPosition(in: straightened) else {
                    XCTFail("转正 \(turns) 格之后标记像素丢了")
                    continue
                }

                // 识别器会以这块像素在转正图里的位置报框，我们把它转回原图坐标。
                let reported = pixelQuad(
                    found,
                    inImageOf: straightened.width,
                    height: straightened.height
                )
                let mapped = reported.rotatedClockwise(quarterTurns: turns).boundingBox

                let expected = pixelQuad(marker, inImageOf: width, height: height).boundingBox
                XCTAssertEqual(mapped.minX, expected.minX, accuracy: 1e-9, "turns=\(turns) \(marker)")
                XCTAssertEqual(mapped.minY, expected.minY, accuracy: 1e-9, "turns=\(turns) \(marker)")
                XCTAssertEqual(mapped.width, expected.width, accuracy: 1e-9, "turns=\(turns) \(marker)")
                XCTAssertEqual(mapped.height, expected.height, accuracy: 1e-9, "turns=\(turns) \(marker)")
            }
        }
    }

    // MARK: - token 几何

    func testHorizontalSliceKeepsLineThicknessAndRotation() {
        let line = TextQuad.upright(x: 0.1, y: 0.6, width: 0.5, height: 0.05)
        let lying = line.rotatedClockwise(quarterTurns: 1)
        let slice = lying.horizontalSlice(from: 0.2, to: 0.8)

        XCTAssertEqual(slice.baselineLength, lying.baselineLength * 0.6, accuracy: 1e-9)
        XCTAssertEqual(slice.uprightHeight, lying.uprightHeight, accuracy: 1e-9)
        XCTAssertEqual(slice.angle, lying.angle, accuracy: 1e-9)
    }

    // MARK: - 夹具

    private func snapshot(applied: CGFloat?, level: CGFloat?) -> OrientationSnapshot {
        OrientationSnapshot(
            appliedAngle: applied,
            horizonLevelCapture: level,
            horizonLevelPreview: nil
        )
    }

    /// 像素坐标，原点左上——和 CGImage 的数据行序一致。
    private struct Marker: Equatable, CustomStringConvertible {
        let x: Int
        let y: Int
        var description: String { "(\(x),\(y))" }
    }

    /// 一张全黑的灰度图，只有一个像素是白的。单像素标记让"转到哪去了"没有歧义。
    private func markedImage(width: Int, height: Int, markerX: Int, markerY: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels[markerY * width + markerX] = 255
        let data = CFDataCreate(nil, pixels, pixels.count)!
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// 找最亮的那个像素。转正走的是整数平移 + 90° 整倍旋转，本该是逐像素搬运，
    /// 但取最大值而不是断言"恰好 255"，免得被色彩空间换算的一两级差值绊倒。
    private func markerPosition(in image: CGImage) -> Marker? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let brightest = pixels.indices.max(by: { pixels[$0] < pixels[$1] }),
              pixels[brightest] > 128 else {
            return nil
        }
        return Marker(x: brightest % width, y: brightest / width)
    }

    /// 把一个像素表述成 Vision 归一化坐标的框：原点左下、y 向上。
    private func pixelQuad(_ marker: Marker, inImageOf width: Int, height: Int) -> TextQuad {
        .upright(
            x: CGFloat(marker.x) / CGFloat(width),
            y: 1 - CGFloat(marker.y + 1) / CGFloat(height),
            width: 1 / CGFloat(width),
            height: 1 / CGFloat(height)
        )
    }
}
