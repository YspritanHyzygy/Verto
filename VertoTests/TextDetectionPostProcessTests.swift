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

/// DB 后处理的判据。测的是**行为**不只是常量——常量断言只能防手滑改数，
/// 防不住"把掩膜打分退回包围盒平均"这类实现走样。
final class TextDetectionPostProcessTests: XCTestCase {

    // MARK: - 超参数

    func testHyperParametersFollowTheModelsOwnInferenceConfig() {
        // 这些数来自 PP-OCRv6_*_det_onnx 仓库里的 inference.yml，
        // **不是** PaddleOCR 命令行的默认值（那套是 0.3 / 0.6 / 1.5 / 512，v4 口径，
        // 三个阈值全都更严，曾经抄的就是它）。改这里之前先去看模型自带的配置。
        XCTAssertEqual(TextDetectionPostProcess.binarizationThreshold, 0.2)
        XCTAssertEqual(OCRModelTier.tiny.correctedBoxScoreThreshold, 0.40)
        XCTAssertEqual(OCRModelTier.small.correctedBoxScoreThreshold, 0.45)
        XCTAssertEqual(OCRModelTier.medium.correctedBoxScoreThreshold, 0.45)
        XCTAssertEqual(TextDetectionPostProcess.unclipRatio, 1.4)
        XCTAssertEqual(TextDetectionPostProcess.maximumBoxes, 3000)
    }

    // MARK: - 打分掩膜

    func testTiltedBoxScoresOnlyWhatIsInsideIt() throws {
        // 45° 菱形：概率 1 只填在菱形内，轴对齐包围盒的四个角是 0。
        // 菱形面积正好是包围盒的一半，所以退回"整块包围盒取平均"会得到约 0.5。
        let side = 21
        let corners = [
            CGPoint(x: 10, y: 0),
            CGPoint(x: 20, y: 10),
            CGPoint(x: 10, y: 20),
            CGPoint(x: 0, y: 10),
        ]
        var probabilities = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side where abs(x - 10) + abs(y - 10) <= 10 {
                probabilities[y * side + x] = 1
            }
        }

        let score = TextDetectionPostProcess.meanProbability(
            inside: corners, probabilities: probabilities,
            width: side, validWidth: side, validHeight: side
        )

        XCTAssertGreaterThan(
            score, 0.95,
            "倾斜框的分数被包围盒里的背景拉低了，说明打分没走四边形掩膜"
        )
    }

    func testUprightBoxScoreIsUnaffectedByTheMask() {
        // 水平框时掩膜和包围盒等价——这条保证补掩膜没有顺手削掉内部像素。
        let width = 12, height = 8
        var probabilities = [Float](repeating: 0, count: width * height)
        for y in 2..<6 {
            for x in 1..<11 { probabilities[y * width + x] = 0.8 }
        }
        let corners = [
            CGPoint(x: 1, y: 2), CGPoint(x: 10, y: 2),
            CGPoint(x: 10, y: 5), CGPoint(x: 1, y: 5),
        ]

        let score = TextDetectionPostProcess.meanProbability(
            inside: corners, probabilities: probabilities,
            width: width, validWidth: width, validHeight: height
        )

        XCTAssertEqual(score, 0.8, accuracy: 0.001, "水平框内部像素被掩膜误伤了")
    }

    func testDegenerateCornerCountScoresZero() {
        let probabilities = [Float](repeating: 1, count: 16)
        XCTAssertEqual(
            TextDetectionPostProcess.meanProbability(
                inside: [CGPoint(x: 0, y: 0)], probabilities: probabilities,
                width: 4, validWidth: 4, validHeight: 4
            ),
            0
        )
    }

    // MARK: - 阈值真的在起作用

    func testBlobAtHalfProbabilitySurvivesTheBoxThreshold() throws {
        // 均匀 0.5 的一块：新判据 0.45 收得下，旧判据 0.6 会整块丢掉。
        let width = 32, height = 16
        var probabilities = [Float](repeating: 0, count: width * height)
        for y in 5..<10 {
            for x in 6..<26 { probabilities[y * width + x] = 0.5 }
        }

        let boxes = TextDetectionPostProcess.boxes(
            probabilities: probabilities, width: width, height: height,
            validWidth: width, validHeight: height,
            boxScoreThreshold: OCRModelTier.small.boxScoreThreshold
        )

        XCTAssertEqual(boxes.count, 1, "0.5 的文字块被 box_thresh 毙了，阈值又回到 0.6 了")
        XCTAssertEqual(try XCTUnwrap(boxes.first).score, 0.5, accuracy: 0.05)
    }

    func testFaintFringeJoinsTheComponentAtTheLowerBinarizationThreshold() throws {
        // 左边一段 0.9 的实心，右边接一段 0.25 的淡边。
        // 二值化 0.2 会把淡边一起收进同一个连通块，0.3 则只留实心那段。
        let width = 40, height = 16
        var probabilities = [Float](repeating: 0, count: width * height)
        for y in 5..<9 {
            for x in 4..<16 { probabilities[y * width + x] = 0.9 }
            for x in 16..<24 { probabilities[y * width + x] = 0.25 }
        }

        let boxes = TextDetectionPostProcess.boxes(
            probabilities: probabilities, width: width, height: height,
            validWidth: width, validHeight: height,
            boxScoreThreshold: OCRModelTier.small.boxScoreThreshold
        )
        let box = try XCTUnwrap(boxes.first, "实心块本身就该出框")

        let xs = box.corners.map(\.x)
        let rightEdge = try XCTUnwrap(xs.max())
        let leftEdge = try XCTUnwrap(xs.min())
        let boxWidth = rightEdge - leftEdge
        // 只收实心段（12px）外扩后约 16；连淡边一起收（20px）外扩后约 25。
        XCTAssertGreaterThan(
            boxWidth, 20,
            "淡边没进连通块，说明二值化阈值又回到 0.3 了"
        )
    }

    // MARK: - 外扩框 vs 紧框

    func testBoxCarriesBothExpandedAndUnexpandedCorners() throws {
        // 一行长条文字。裁剪要用外扩框（不扩会切掉首尾字母），但行高、行距、
        // 倾角这些"是否同一段"的判据必须用紧框——外扩距离是
        // w·h·ratio/(2(w+h))，跟长宽比有关，长行扩得多短行扩得少，
        // 拿外扩框当判据等于让阈值随每行的形状漂移。
        let width = 64, height = 24
        var probabilities = [Float](repeating: 0, count: width * height)
        let blobTop = 9, blobBottom = 15, blobLeft = 6, blobRight = 54
        for y in blobTop..<blobBottom {
            for x in blobLeft..<blobRight { probabilities[y * width + x] = 1 }
        }

        let boxes = TextDetectionPostProcess.boxes(
            probabilities: probabilities, width: width, height: height,
            validWidth: width, validHeight: height,
            boxScoreThreshold: OCRModelTier.small.boxScoreThreshold
        )
        let box = try XCTUnwrap(boxes.first)

        func extent(_ corners: [CGPoint]) -> (width: CGFloat, height: CGFloat) {
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return (xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        }
        let expanded = extent(box.corners)
        let tight = extent(box.tightCorners)

        // 紧框贴着连通块本身（宽 48、高 6，量化误差算一像素）。
        XCTAssertEqual(tight.width, CGFloat(blobRight - blobLeft - 1), accuracy: 1.5)
        XCTAssertEqual(tight.height, CGFloat(blobBottom - blobTop - 1), accuracy: 1.5)

        // 外扩框在两个方向上都更大；长行的高度会被扩到约 2.4 倍，
        // 正是这个倍数让"行距 ≤ 1.6 倍行高"的判据松掉约三倍。
        XCTAssertGreaterThan(expanded.height, tight.height * 1.8)
        XCTAssertGreaterThan(expanded.width, tight.width)
    }

    // MARK: - letterbox 补边

    func testPaddingOutsideTheValidAreaIsIgnored() {
        // 检测输入是补成正方形的，补边区必须不参与连通域分析，
        // 否则黑边会和图像内容连成一个巨框。这里把补边区填满高概率，
        // 有效区留空——不该出任何框。
        let side = 24
        let valid = 12
        var probabilities = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side where x >= valid || y >= valid {
                probabilities[y * side + x] = 1
            }
        }

        let boxes = TextDetectionPostProcess.boxes(
            probabilities: probabilities, width: side, height: side,
            validWidth: valid, validHeight: valid,
            boxScoreThreshold: OCRModelTier.small.boxScoreThreshold
        )

        XCTAssertTrue(boxes.isEmpty, "补边区被当成文字了")
    }

    func testTinyKeepsAWeakBoxThatSmallAndMediumReject() {
        let width = 16, height = 12
        var probabilities = [Float](repeating: 0, count: width * height)
        for y in 3..<9 {
            for x in 3..<13 { probabilities[y * width + x] = 0.425 }
        }

        func count(for tier: OCRModelTier) -> Int {
            TextDetectionPostProcess.boxes(
                probabilities: probabilities, width: width, height: height,
                validWidth: width, validHeight: height,
                boxScoreThreshold: tier.correctedBoxScoreThreshold
            ).count
        }

        XCTAssertEqual(count(for: .tiny), 1)
        XCTAssertEqual(count(for: .small), 0)
        XCTAssertEqual(count(for: .medium), 0)
    }
}
