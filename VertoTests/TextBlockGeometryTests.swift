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

import SwiftUI
import XCTest
@testable import Verto

/// 叠加层的坐标换算与行→段合并都是纯函数，这里钉死它们的行为——
/// 这两处一旦错位，译文贴片会整体偏移或把两段文字粘成一段，
/// 而截图上未必一眼看得出是"错"还是"这张图就长这样"。
final class TextBlockGeometryTests: XCTestCase {
    private func line(
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> RecognizedTextBlock {
        RecognizedTextBlock(text: text, quad: .upright(x: x, y: y, width: width, height: height))
    }

    // MARK: - TextQuad

    func testUprightQuadReportsZeroAngleAndItsOwnBox() {
        let quad = TextQuad.upright(x: 0.2, y: 0.5, width: 0.4, height: 0.1)

        XCTAssertEqual(quad.angle, 0, accuracy: 1e-9)
        XCTAssertEqual(quad.boundingBox.minX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(quad.boundingBox.minY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(quad.baselineLength, 0.4, accuracy: 1e-9)
        XCTAssertEqual(quad.uprightHeight, 0.1, accuracy: 1e-9)
    }

    func testTiltedQuadHeightIgnoresBoundingBoxInflation() {
        // 基线抬高 0.1 的斜置行：包围盒高度被水平投影撑大，行高必须仍是垂直边长。
        let quad = TextQuad(
            topLeft: CGPoint(x: 0.1, y: 0.5),
            topRight: CGPoint(x: 0.5, y: 0.6),
            bottomRight: CGPoint(x: 0.5, y: 0.5),
            bottomLeft: CGPoint(x: 0.1, y: 0.4)
        )

        XCTAssertGreaterThan(quad.boundingBox.height, quad.uprightHeight)
        XCTAssertEqual(quad.uprightHeight, 0.1, accuracy: 1e-9)
        XCTAssertGreaterThan(quad.angle, 0, "Vision 坐标 y 向上，基线右端更高即正角")
    }

    func testUnionTakesOutermostCorners() {
        let upper = TextQuad.upright(x: 0.2, y: 0.6, width: 0.3, height: 0.05)
        let lower = TextQuad.upright(x: 0.1, y: 0.5, width: 0.5, height: 0.05)

        let union = upper.union(lower)

        XCTAssertEqual(union.boundingBox.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(union.boundingBox.maxX, 0.6, accuracy: 1e-9)
        XCTAssertEqual(union.boundingBox.minY, 0.5, accuracy: 1e-9)
        XCTAssertEqual(union.boundingBox.maxY, 0.65, accuracy: 1e-9)
    }

    // MARK: - OverlayGeometry

    func testAspectFillSizeCropsTallImageInWideContainer() {
        let size = OverlayGeometry.aspectFillSize(
            imageSize: CGSize(width: 100, height: 200),
            in: CGSize(width: 400, height: 200)
        )

        // 高图填满宽容器：宽度贴合、上下裁切，结果默认构图才会和 aspectFill 取景一致。
        XCTAssertEqual(size.width, 400, accuracy: 1e-9)
        XCTAssertEqual(size.height, 800, accuracy: 1e-9)
    }

    func testAspectFillSizeIsZeroForDegenerateSizes() {
        XCTAssertEqual(
            OverlayGeometry.aspectFillSize(imageSize: .zero, in: CGSize(width: 10, height: 10)),
            .zero
        )
        XCTAssertEqual(
            OverlayGeometry.aspectFillSize(imageSize: CGSize(width: 10, height: 10), in: .zero),
            .zero
        )
    }

    func testMinimumZoomScaleFitsTheWholeAspectFillCanvas() {
        let scale = OverlayGeometry.minimumZoomScale(
            canvasSize: CGSize(width: 400, height: 800),
            viewportSize: CGSize(width: 400, height: 200)
        )

        XCTAssertEqual(scale, 0.25, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(400 * scale, 400)
        XCTAssertLessThanOrEqual(800 * scale, 200)
    }

    func testRotatedStickerHitTestingUsesItsRealShape() {
        let angle = Angle.degrees(45)
        let center = CGPoint(x: 100, y: 100)

        XCTAssertTrue(OverlayGeometry.contains(
            CGPoint(x: 121, y: 121),
            inRotatedRectAt: center,
            size: CGSize(width: 80, height: 20),
            angle: angle
        ))
        XCTAssertFalse(OverlayGeometry.contains(
            CGPoint(x: 130, y: 100),
            inRotatedRectAt: center,
            size: CGSize(width: 80, height: 20),
            angle: angle
        ), "轴对齐包围盒内、旋转贴片外的角落不应误开详情")
    }

    func testPointConversionFlipsVisionYAxis() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 200)

        // Vision 的 y=1 是图片顶边，视图里对应 y=0。
        let top = OverlayGeometry.point(CGPoint(x: 0.5, y: 1), in: display)
        let bottom = OverlayGeometry.point(CGPoint(x: 0.5, y: 0), in: display)

        XCTAssertEqual(top, CGPoint(x: 50, y: 0))
        XCTAssertEqual(bottom, CGPoint(x: 50, y: 200))
    }

    func testPointConversionRespectsLetterboxOffset() {
        let display = CGRect(x: 150, y: 20, width: 100, height: 200)

        let point = OverlayGeometry.point(CGPoint(x: 0, y: 1), in: display)

        XCTAssertEqual(point, CGPoint(x: 150, y: 20), "留白偏移必须计入，否则整层块左上偏")
    }

    func testPlaceMapsUprightQuadToCenteredBox() {
        let display = CGRect(x: 0, y: 0, width: 200, height: 100)
        let quad = TextQuad.upright(x: 0.25, y: 0.5, width: 0.5, height: 0.2)

        let placement = OverlayGeometry.place(quad, in: display)

        XCTAssertEqual(placement.center.x, 100, accuracy: 1e-9)
        // Vision 的 y 区间 0.5...0.7，中点 0.6 → 视图 (1 - 0.6) * 100 = 40。
        XCTAssertEqual(placement.center.y, 40, accuracy: 1e-9)
        XCTAssertEqual(placement.size.width, 100, accuracy: 1e-9)
        XCTAssertEqual(placement.size.height, 20, accuracy: 1e-9)
        XCTAssertEqual(placement.angle.radians, 0, accuracy: 1e-9)
    }

    func testPlaceNegatesAngleWhenCrossingIntoViewSpace() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 100)
        let quad = TextQuad(
            topLeft: CGPoint(x: 0.1, y: 0.5),
            topRight: CGPoint(x: 0.5, y: 0.6),
            bottomRight: CGPoint(x: 0.5, y: 0.5),
            bottomLeft: CGPoint(x: 0.1, y: 0.4)
        )

        let placement = OverlayGeometry.place(quad, in: display)

        // Vision 里正角（右端更高），视图 y 向下，落到视图必须是负角；
        // 符号搞反时贴片会朝反方向倾斜，正好是"看起来有转，但转反了"的隐蔽错误。
        XCTAssertGreaterThan(quad.angle, 0)
        XCTAssertLessThan(placement.angle.radians, 0)
        XCTAssertEqual(placement.angle.radians, -Double(quad.angle), accuracy: 1e-9)
    }

    // MARK: - TextBlockGrouping

    func testAdjacentLinesInSameColumnMergeIntoOneBlock() {
        let lines = [
            line(text: "Second line", x: 0.1, y: 0.50, width: 0.5, height: 0.04),
            line(text: "First line", x: 0.1, y: 0.56, width: 0.5, height: 0.04),
        ]

        let blocks = TextBlockGrouping.group(lines: lines)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.lineCount, 2)
        XCTAssertEqual(blocks.first?.text, "First line Second line", "自上而下拼接，拉丁文之间补空格")
    }

    func testFarApartLinesStaySeparateBlocks() {
        let lines = [
            line(text: "标题", x: 0.1, y: 0.80, width: 0.5, height: 0.04),
            line(text: "页脚", x: 0.1, y: 0.10, width: 0.5, height: 0.04),
        ]

        XCTAssertEqual(TextBlockGrouping.group(lines: lines).count, 2)
    }

    func testSideBySideColumnsDoNotMerge() {
        // 分栏菜单：左右两列水平投影零重叠，纵向再近也不许并成一段。
        let lines = [
            line(text: "宫保鸡丁", x: 0.05, y: 0.50, width: 0.30, height: 0.04),
            line(text: "¥32", x: 0.60, y: 0.495, width: 0.20, height: 0.04),
        ]

        XCTAssertEqual(TextBlockGrouping.group(lines: lines).count, 2)
    }

    func testHeadingDoesNotMergeWithBodyBelowIt() {
        // 真实 Vision 实测出来的漏网之鱼：标题与紧邻正文只差一行间距，
        // 光看间距会被并成一段，译文变成一长串。字号差别才是判据。
        let heading = line(text: "欢迎光临", x: 0.14, y: 0.70, width: 0.52, height: 0.075)
        let body = line(text: "营业时间 09:00-21:00", x: 0.14, y: 0.62, width: 0.72, height: 0.040)

        XCTAssertFalse(TextBlockGrouping.belongsToSameBlock(heading, body))
        XCTAssertEqual(TextBlockGrouping.group(lines: [heading, body]).count, 2)
    }

    func testSlightlyDifferentLineHeightsStillMerge() {
        // 同段内相邻行的行高差只来自升降部，不该被字号规则误伤。
        let upper = line(text: "The sunset is", x: 0.1, y: 0.56, width: 0.5, height: 0.040)
        let lower = line(text: "especially beautiful", x: 0.1, y: 0.50, width: 0.5, height: 0.044)

        XCTAssertTrue(TextBlockGrouping.belongsToSameBlock(upper, lower))
    }

    func testStronglyTiltedLineDoesNotMergeWithFlatLine() {
        let flat = line(text: "平的", x: 0.1, y: 0.56, width: 0.5, height: 0.04)
        let tilted = RecognizedTextBlock(
            text: "斜的",
            quad: TextQuad(
                topLeft: CGPoint(x: 0.1, y: 0.54),
                topRight: CGPoint(x: 0.6, y: 0.70),
                bottomRight: CGPoint(x: 0.6, y: 0.66),
                bottomLeft: CGPoint(x: 0.1, y: 0.50)
            )
        )

        XCTAssertFalse(TextBlockGrouping.belongsToSameBlock(flat, tilted))
    }

    func testCJKLinesJoinWithoutSpace() {
        let lines = [
            line(text: "海边走走", x: 0.1, y: 0.50, width: 0.5, height: 0.04),
            line(text: "我想和你一起去", x: 0.1, y: 0.56, width: 0.5, height: 0.04),
        ]

        let blocks = TextBlockGrouping.group(lines: lines)

        XCTAssertEqual(blocks.first?.text, "我想和你一起去海边走走", "中文行尾补空格会在译文里留下多余分词")
    }

    func testGroupingOrdersLinesTopDownThenLeftToRight() {
        let lines = [
            line(text: "右上", x: 0.55, y: 0.80, width: 0.3, height: 0.04),
            line(text: "下方", x: 0.10, y: 0.20, width: 0.3, height: 0.04),
            line(text: "左上", x: 0.10, y: 0.80, width: 0.3, height: 0.04),
        ]

        let blocks = TextBlockGrouping.group(lines: lines)

        XCTAssertEqual(blocks.map(\.text), ["左上", "右上", "下方"])
    }

    func testBlockConfidenceTakesWeakestLine() {
        let lines = [
            RecognizedTextBlock(text: "A", quad: .upright(x: 0.1, y: 0.56, width: 0.5, height: 0.04), confidence: 0.9),
            RecognizedTextBlock(text: "B", quad: .upright(x: 0.1, y: 0.50, width: 0.5, height: 0.04), confidence: 0.4),
        ]

        XCTAssertEqual(TextBlockGrouping.group(lines: lines).first?.confidence, 0.4)
    }

    // MARK: - Vision 语言码

    func testVisionLanguageCodesDifferFromSpeechForSimplifiedChinese() {
        // zh-CN 不在 Vision 支持列表里，传进去会被静默忽略、退化成按英文识别中文。
        XCTAssertEqual(Language.chinese.visionRecognitionLanguage, "zh-Hans")
        XCTAssertEqual(Language.chinese.speechLocaleIdentifier, "zh-CN")
        XCTAssertNotEqual(
            Language.chinese.visionRecognitionLanguage,
            Language.chinese.speechLocaleIdentifier
        )
    }

    func testEveryLanguageHasANonEmptyVisionCode() {
        for language in Language.all {
            XCTAssertFalse(language.visionRecognitionLanguage.isEmpty, "\(language.code) 缺 Vision 语言码")
        }
    }
}
