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

private struct DelayedNeuralPhotoReconstructor: NeuralPhotoReconstructing {
    func reconstruct(
        image: UIImage,
        blocks: [PhotoTranslationController.TranslatedBlock]
    ) throws -> PhotoReconstructionResult {
        Thread.sleep(forTimeInterval: 0.08)
        return PhotoReconstructionResult(
            image: image,
            inlinedBlockIDs: Set(blocks.map(\.id)),
            unresolvedBlockIDs: [],
            backend: .neural
        )
    }
}

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

    /// 造一行，紧框与外扩框分开给——模拟 PP-OCRv6：DB 出的是收缩多边形，
    /// `unclip_ratio` 再把它上下左右各撑开一截还原成真实字形边界。
    private func detectedLine(
        text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        tightHeight: CGFloat,
        expandBy: CGFloat
    ) -> RecognizedTextBlock {
        RecognizedTextBlock(
            text: text,
            quad: .upright(
                x: x - expandBy,
                y: y - expandBy,
                width: width + expandBy * 2,
                height: tightHeight + expandBy * 2
            ),
            metricsQuad: .upright(x: x, y: y, width: width, height: tightHeight)
        )
    }

    // MARK: - 两个框各司其职

    /// 合并出来的块必须带**能盖住原文**的那个框。
    ///
    /// 这里防的是一次真实回归：为了让阈值口径一致，块的 quad 曾被整个换成紧框，
    /// 于是贴片按收缩框画，只压住字的中间一条，上下都露着原文。
    /// 收缩框只配当尺子，不配当画布。
    func testMergedBlockCarriesTheCoveringQuadNotTheTightOne() {
        let lines = [
            detectedLine(text: "第一行", x: 0.1, y: 0.5, width: 0.5, tightHeight: 0.02, expandBy: 0.014),
            detectedLine(text: "第二行", x: 0.1, y: 0.478, width: 0.5, tightHeight: 0.02, expandBy: 0.014)
        ]

        let blocks = TextBlockGrouping.group(lines: lines)

        XCTAssertEqual(blocks.count, 1, "同段两行没合并")
        let box = blocks[0].quad.boundingBox
        // 外扩框的并集：0.464…0.534。紧框的并集只有 0.478…0.52。
        XCTAssertEqual(box.minY, 0.464, accuracy: 1e-9)
        XCTAssertEqual(box.height, 0.070, accuracy: 1e-9)
    }

    /// 而判据读的必须是紧框。
    ///
    /// 这两行的紧框间距是行高的 4 倍，明显不同段；但外扩之后间距只剩行高的 1.08 倍，
    /// 拿外扩框当判据就会把它们并成一块——外扩量随长宽比变化，阈值会跟着每行形状漂移。
    func testGroupingThresholdsReadTheTightQuad() {
        let lines = [
            detectedLine(text: "标题", x: 0.1, y: 0.5, width: 0.5, tightHeight: 0.02, expandBy: 0.014),
            detectedLine(text: "很靠下的另一段", x: 0.1, y: 0.4, width: 0.5, tightHeight: 0.02, expandBy: 0.014)
        ]

        let blocks = TextBlockGrouping.group(lines: lines)

        XCTAssertEqual(blocks.count, 2, "隔了 4 倍行高的两行被并成了一块")
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
        XCTAssertEqual(blocks.first?.lines.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(blocks.first?.lines.flatMap(\.tokens).map(\.text), ["First line", "Second line"])
    }

    func testLatinTokenizationKeepsAdjacentPunctuation() {
        XCTAssertEqual(
            TextTokenization.ranges(in: "Hello, world!").map(\.text),
            ["Hello,", "world!"]
        )
    }

    func testNeuralPolicyUsesRuntimeMeasurementsAndPowerState() {
        XCTAssertTrue(NeuralReconstructionPolicy.allows(
            medianSeconds: 0.8,
            regionCount: 4,
            lowPowerMode: false,
            thermalState: .nominal,
            hadMemoryWarning: false
        ))
        XCTAssertFalse(NeuralReconstructionPolicy.allows(
            medianSeconds: 1.01,
            regionCount: 1,
            lowPowerMode: false,
            thermalState: .nominal,
            hadMemoryWarning: false
        ))
        XCTAssertFalse(NeuralReconstructionPolicy.allows(
            medianSeconds: 0.9,
            regionCount: 7,
            lowPowerMode: false,
            thermalState: .nominal,
            hadMemoryWarning: false
        ))
        XCTAssertFalse(NeuralReconstructionPolicy.allows(
            medianSeconds: 0.5,
            regionCount: 1,
            lowPowerMode: true,
            thermalState: .serious,
            hadMemoryWarning: false
        ))
    }

    @MainActor
    func testNeuralWatchdogFallsBackBeforeLateResultCanPublish() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            ("SALE" as NSString).draw(
                in: CGRect(x: 24, y: 24, width: 72, height: 24),
                withAttributes: [.foregroundColor: UIColor.black]
            )
        }
        let recognized = RecognizedTextBlock(
            text: "SALE",
            quad: .upright(x: 0.2, y: 0.3, width: 0.6, height: 0.3)
        )
        let block = PhotoTranslationController.TranslatedBlock(
            id: recognized.id,
            source: recognized.text,
            translation: "GO",
            isPending: false,
            failure: nil,
            lines: recognized.lines
        )

        let result = try await PhotoReconstructionPipeline(
            watchdogDuration: .milliseconds(5)
        ).reconstruct(
            image: image,
            blocks: [block],
            route: .neural(DelayedNeuralPhotoReconstructor())
        )

        XCTAssertEqual(result.backend, .adaptive)
    }

    @MainActor
    func testAdaptiveReconstructionChangesOnlyAnAcceptedFlatTextRegion() throws {
        let size = CGSize(width: 240, height: 120)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.9, green: 0.84, blue: 0.7, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("SALE" as NSString).draw(
                in: CGRect(x: 48, y: 42, width: 144, height: 36),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 30, weight: .bold),
                    .foregroundColor: UIColor.black,
                ]
            )
        }
        let recognized = RecognizedTextBlock(
            text: "SALE",
            quad: .upright(x: 0.2, y: 0.35, width: 0.6, height: 0.3)
        )
        let block = PhotoTranslationController.TranslatedBlock(
            id: recognized.id,
            source: recognized.text,
            translation: "GO",
            isPending: false,
            failure: nil,
            lines: recognized.lines
        )

        let result = try AdaptiveBackgroundReconstructor().reconstruct(
            image: image,
            blocks: [block]
        )

        XCTAssertEqual(result.inlinedBlockIDs, [block.id])
        XCTAssertTrue(result.unresolvedBlockIDs.isEmpty)
        let sourceCG = try XCTUnwrap(image.cgImage)
        let resultCG = try XCTUnwrap(result.image.cgImage)
        let before = try rgbaBytes(in: sourceCG)
        let after = try rgbaBytes(in: resultCG)
        let allowed = recognized.quad.boundingBox
        let minX = Int(floor(allowed.minX * CGFloat(sourceCG.width)))
        let maxX = Int(ceil(allowed.maxX * CGFloat(sourceCG.width)))
        let minY = Int(floor(allowed.minY * CGFloat(sourceCG.height)))
        let maxY = Int(ceil(allowed.maxY * CGFloat(sourceCG.height)))
        var changedInside = 0
        for y in 0..<sourceCG.height {
            for x in 0..<sourceCG.width {
                let offset = (y * sourceCG.width + x) * 4
                let changed = before[offset..<(offset + 4)] != after[offset..<(offset + 4)]
                let safelyOutsideLine = x < minX || x >= maxX || y < minY || y >= maxY
                if safelyOutsideLine {
                    XCTAssertFalse(changed, "文字区域外像素变化：\(x),\(y)")
                } else if changed {
                    changedInside += 1
                }
            }
        }
        XCTAssertGreaterThan(changedInside, 0)
    }

    func testNeuralBlendPreservesKnownPixelsAndUsesGeneratedHole() {
        let original: [UInt8] = [10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255]
        let generated: [UInt8] = [200, 210, 220, 255, 230, 240, 250, 255, 100, 110, 120, 255]

        let result = NeuralBackgroundReconstructor.blendGeneratedPixels(
            generated,
            with: original,
            knownMask: [255, 0, 128]
        )

        XCTAssertEqual(Array(result[0..<4]), Array(original[0..<4]))
        XCTAssertEqual(Array(result[4..<8]), Array(generated[4..<8]))
        XCTAssertEqual(result[8], 85)
        XCTAssertEqual(result[9], 95)
        XCTAssertEqual(result[10], 105)
        XCTAssertEqual(result[11], 255)
    }

    @MainActor
    func testAdaptivePixelGuardDrawsOnlyInsideAcceptedLine() throws {
        let size = CGSize(width: 40, height: 40)
        let original = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let rendered = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let line = RecognizedTextBlock(
            text: "x",
            quad: .upright(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        ).lines[0]

        let guarded = try XCTUnwrap(
            AdaptiveBackgroundReconstructor.copyOriginalPixelsOutsideLines(
                original: XCTUnwrap(original.cgImage),
                rendered: XCTUnwrap(rendered.cgImage),
                lines: [line]
            )
        )
        let bytes = try rgbaBytes(in: guarded)
        let width = guarded.width
        let height = guarded.height
        let inside = ((height / 2) * width + width / 2) * 4
        let outside = (2 * width + 2) * 4
        XCTAssertEqual(Array(bytes[inside..<(inside + 3)]), [0, 0, 255])
        XCTAssertEqual(Array(bytes[outside..<(outside + 3)]), [255, 0, 0])
    }

    func testAdaptiveReconstructionStopsAfterCancellation() async throws {
        let task = Task.detached { () throws -> PhotoReconstructionResult in
            await Task.yield()
            return try AdaptiveBackgroundReconstructor().reconstruct(
                image: UIImage(),
                blocks: []
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后的重建任务仍返回了结果")
        } catch is CancellationError {
            // 取消沿调用链返回，旧渲染不会继续占用后续代次。
        }
    }

    @MainActor
    func testOpenBlockCardRefreshesWhenTranslationCompletes() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        let recognized = RecognizedTextBlock(
            text: "原文",
            quad: .upright(x: 0.2, y: 0.3, width: 0.6, height: 0.25)
        )
        let pending = PhotoTranslationController.TranslatedBlock(
            id: recognized.id,
            source: recognized.text,
            translation: "",
            isPending: true,
            failure: nil,
            lines: recognized.lines
        )
        let completed = PhotoTranslationController.TranslatedBlock(
            id: recognized.id,
            source: recognized.text,
            translation: "Done",
            isPending: false,
            failure: nil,
            lines: recognized.lines
        )
        let actions = TranslatedPhotoCanvas.Actions(
            translateSelection: { _ in .success("Done") },
            isSelectionCurrent: { true },
            speak: { _, _ in },
            save: { _, _ in },
            retryBlock: { _ in }
        )
        let photoID = UUID()
        let view = TranslatedPhotoCanvasView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.configure(
            photoID: photoID,
            generation: 1,
            originalImage: image,
            translatedImage: nil,
            blocks: [pending],
            mode: .translation,
            actions: actions
        )
        view.layoutIfNeeded()
        let blockElement = try XCTUnwrap(
            view.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
                .first(where: { $0.accessibilityIdentifier == "camera.block.0" })
        )
        XCTAssertTrue(blockElement.accessibilityActivate())
        let label = try XCTUnwrap(
            descendant(in: view, accessibilityIdentifier: "camera.selectionCard.translation") as? UILabel
        )
        XCTAssertEqual(label.text, String(localized: "正在翻译…"))

        view.configure(
            photoID: photoID,
            generation: 1,
            originalImage: image,
            translatedImage: nil,
            blocks: [completed],
            mode: .translation,
            actions: actions
        )
        XCTAssertEqual(label.text, "Done")

        let close = try XCTUnwrap(
            descendant(in: view, accessibilityIdentifier: "camera.selectionCard.close") as? UIButton
        )
        let card = try XCTUnwrap(
            descendant(in: view, accessibilityIdentifier: "camera.selectionCard")
        )
        close.sendActions(for: .touchUpInside)
        XCTAssertTrue(card.isHidden)
        view.configure(
            photoID: photoID,
            generation: 1,
            originalImage: image,
            translatedImage: nil,
            blocks: [completed],
            mode: .translation,
            actions: actions
        )
        XCTAssertTrue(card.isHidden, "用户关闭的段落卡被下一次画布更新重新打开")
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

    func testStaircaseDriftDoesNotChainIntoOneBlock() {
        // 每行右移一点点，逐对都刚好过 30% 重叠线，四行之后首尾已经毫不相干。
        // 只跟上一行比就会把它们串成一块，`union` 再把中间整片圈进同一个框。
        let lines = (0..<4).map { index in
            line(
                text: "L\(index)",
                x: 0.05 + CGFloat(index) * 0.20,
                y: 0.86 - CGFloat(index) * 0.06,
                width: 0.30,
                height: 0.04
            )
        }

        // 前提：逐对判据确实拦不住，所以这个用例考的是块级判据。
        XCTAssertTrue(TextBlockGrouping.belongsToSameBlock(lines[0], lines[1]))
        XCTAssertTrue(TextBlockGrouping.belongsToSameBlock(lines[1], lines[2]))

        let blocks = TextBlockGrouping.group(lines: lines)

        XCTAssertGreaterThan(blocks.count, 1, "阶梯式漂移不该串成一块")
        XCTAssertNil(
            blocks.first(where: { $0.quad.boundingBox.width > 0.8 }),
            "没有哪一块该横跨整幅画面"
        )
    }

    func testLongUniformParagraphStillMergesIntoOneBlock() {
        // 刹车不能误伤真实段落：同栏、同字号、行距正常的十二行仍是一段，
        // 逐行翻译会把一句话切碎。
        let lines = (0..<12).map { index in
            line(
                text: "line\(index)",
                x: 0.12,
                y: 0.90 - CGFloat(index) * 0.055,
                width: 0.60,
                height: 0.04
            )
        }

        let blocks = TextBlockGrouping.group(lines: lines)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.lineCount, 12)
    }

    func testGradualFontSizeDriftDoesNotChainIntoOneBlock() {
        // 字号每行缩一点，逐对都在 1.4 倍以内，四行之后首尾差了 1.6 倍——
        // 那已经是两个层级，不是同一段的换行。横向的阶梯漂移由上一个用例覆盖，
        // 这个考的是纵向（字号）的同一种漂移。
        let heights: [CGFloat] = [0.050, 0.042, 0.036, 0.031]
        let tops: [CGFloat] = [0.800, 0.740, 0.690, 0.640]
        let lines = zip(heights, tops).enumerated().map { index, pair in
            line(text: "L\(index)", x: 0.14, y: pair.1, width: 0.60, height: pair.0)
        }

        // 前提：逐对判据全都放行，所以拦下它的只能是块级判据。
        for index in 0..<(lines.count - 1) {
            XCTAssertTrue(
                TextBlockGrouping.belongsToSameBlock(lines[index], lines[index + 1]),
                "第 \(index) 与 \(index + 1) 行本就该逐对合格，用例前提不成立了"
            )
        }

        let blocks = TextBlockGrouping.group(lines: lines)

        XCTAssertGreaterThan(blocks.count, 1, "字号一路漂移不该串成一块")
        XCTAssertFalse(
            TextBlockGrouping.belongsToBlock(Array(lines.prefix(3)), line: lines[3]),
            "首行 0.050 与末行 0.031 差 1.6 倍，块级判据必须拦下"
        )
    }

    func testReadingOrderIsStableRegardlessOfInputOrder() {
        // 顶边两两相差 0.015、容差 0.02：A≈B、B≈C 却 A≉C。带容差的比较器在这种
        // 输入上不是严格弱序，`sorted` 的结果未定义——同一张图两次识别可能得到
        // 不同的行序。这是"竖屏有时候正常有时候不对"的来源。
        let a = line(text: "A", x: 0.60, y: 0.460, width: 0.20, height: 0.04)
        let b = line(text: "B", x: 0.30, y: 0.445, width: 0.20, height: 0.04)
        let c = line(text: "C", x: 0.10, y: 0.430, width: 0.20, height: 0.04)

        let permutations = [[a, b, c], [c, b, a], [b, a, c], [a, c, b], [c, a, b], [b, c, a]]
        let orders = permutations.map { TextBlockGrouping.readingOrder($0).map(\.text) }

        XCTAssertEqual(
            Set(orders).count, 1,
            "输入次序不该影响阅读序，实际得到 \(Set(orders))"
        )
    }

    func testPunctuationOnlyLinesAreDroppedBeforeGrouping() {
        // 反光和 logo 边缘会被 OCR 认成一两个标点。这种块照样会被贴一张有底色的贴片，
        // 在照片上就是一坨没有字的怪色块——真机截图里那个云朵状的东西就是两个叠在一起。
        let junk = line(text: ":", x: 0.10, y: 0.60, width: 0.04, height: 0.02)
        let alsoJunk = line(text: "…）", x: 0.20, y: 0.40, width: 0.05, height: 0.02)
        let real = line(text: "营业时间", x: 0.10, y: 0.20, width: 0.40, height: 0.04)

        let blocks = TextBlockGrouping.group(lines: [junk, alsoJunk, real])

        XCTAssertEqual(blocks.map(\.text), ["营业时间"])
    }

    func testContentDetectionAcceptsEveryScriptTheAppTranslates() {
        for text in ["A", "9", "中", "あ", "한", "café"] {
            XCTAssertTrue(TextBlockGrouping.carriesContent(text), "\(text) 被误判为无内容")
        }
        for text in [":", " ", "", "…）", "——", "•"] {
            XCTAssertFalse(TextBlockGrouping.carriesContent(text), "\(text) 应当算无内容")
        }
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

    private func rgbaBytes(in image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard drew else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }

    @MainActor
    private func descendant(
        in view: UIView,
        accessibilityIdentifier: String
    ) -> UIView? {
        if view.accessibilityIdentifier == accessibilityIdentifier { return view }
        for subview in view.subviews {
            if let match = descendant(
                in: subview,
                accessibilityIdentifier: accessibilityIdentifier
            ) {
                return match
            }
        }
        return nil
    }
}
