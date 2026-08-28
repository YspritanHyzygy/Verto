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
import CoreImage
import CoreText
import SwiftUI
import UIKit

enum PhotoDisplayMode: String, Equatable {
    case original
    case translation
}

enum OverlayGeometry {
    struct Placement: Equatable {
        var center: CGPoint
        var size: CGSize
        var angle: Angle
    }

    static func aspectFillSize(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = max(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func minimumZoomScale(canvasSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return 1
        }
        return min(
            min(viewportSize.width / canvasSize.width, viewportSize.height / canvasSize.height),
            1
        )
    }

    static func point(_ normalized: CGPoint, in displayRect: CGRect) -> CGPoint {
        CGPoint(
            x: displayRect.minX + normalized.x * displayRect.width,
            y: displayRect.minY + (1 - normalized.y) * displayRect.height
        )
    }

    static func place(_ quad: TextQuad, in displayRect: CGRect) -> Placement {
        let topLeft = point(quad.topLeft, in: displayRect)
        let topRight = point(quad.topRight, in: displayRect)
        let bottomLeft = point(quad.bottomLeft, in: displayRect)
        let bottomRight = point(quad.bottomRight, in: displayRect)
        let center = CGPoint(
            x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4,
            y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4
        )
        let width = max(
            hypot(topRight.x - topLeft.x, topRight.y - topLeft.y),
            hypot(bottomRight.x - bottomLeft.x, bottomRight.y - bottomLeft.y)
        )
        let height = max(
            hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y),
            hypot(bottomRight.x - topRight.x, bottomRight.y - topRight.y)
        )
        return Placement(
            center: center,
            size: CGSize(width: width, height: height),
            angle: .radians(Double(atan2(topRight.y - topLeft.y, topRight.x - topLeft.x)))
        )
    }

    static func contains(
        _ point: CGPoint,
        inRotatedRectAt center: CGPoint,
        size: CGSize,
        angle: Angle
    ) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let radians = CGFloat(angle.radians)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let localX = dx * cos(radians) + dy * sin(radians)
        let localY = -dx * sin(radians) + dy * cos(radians)
        return abs(localX) <= size.width / 2 && abs(localY) <= size.height / 2
    }
}

struct PhotoReconstructionResult: @unchecked Sendable {
    let image: UIImage
    let inlinedBlockIDs: Set<UUID>
    let unresolvedBlockIDs: Set<UUID>
}

protocol PhotoReconstructing: Sendable {
    func reconstruct(
        image: UIImage,
        blocks: [PhotoTranslationController.TranslatedBlock]
    ) throws -> PhotoReconstructionResult
}

/// 在低纹理区域按原图像素生成保守字形掩码，填回局部背景，再绘制译文。
struct AdaptiveBackgroundReconstructor: PhotoReconstructing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func reconstruct(
        image: UIImage,
        blocks: [PhotoTranslationController.TranslatedBlock]
    ) throws -> PhotoReconstructionResult {
        try Task.checkCancellation()
        guard let cgImage = image.cgImage else {
            return PhotoReconstructionResult(
                image: image,
                inlinedBlockIDs: [],
                unresolvedBlockIDs: Set(blocks.map(\.id))
            )
        }
        var composed = CIImage(cgImage: cgImage)
        let extent = composed.extent
        var acceptedLines: [RecognizedTextLine] = []
        var inlined: Set<UUID> = []
        var unresolved: Set<UUID> = []

        for block in blocks {
            try Task.checkCancellation()
            guard !block.isPending, !block.failed, !block.translation.isEmpty,
                  let segments = TranslationLineLayout.segments(
                    text: block.translation,
                    count: block.lines.count
                  ) else {
                unresolved.insert(block.id)
                continue
            }

            var patches: [LinePatch] = []
            for (line, text) in zip(block.lines, segments) {
                try Task.checkCancellation()
                guard let patch = try makePatch(
                    source: composed,
                    line: line,
                    translation: text,
                    extent: extent
                ) else {
                    patches = []
                    break
                }
                patches.append(patch)
            }
            guard patches.count == block.lines.count else {
                unresolved.insert(block.id)
                continue
            }
            for patch in patches {
                try Task.checkCancellation()
                composed = patch.background.composited(over: composed).cropped(to: extent)
                composed = patch.text.composited(over: composed).cropped(to: extent)
            }
            acceptedLines.append(contentsOf: block.lines)
            inlined.insert(block.id)
        }

        try Task.checkCancellation()
        guard let rendered = context.createCGImage(composed, from: extent),
              let output = Self.copyOriginalPixelsOutsideLines(
                original: cgImage,
                rendered: rendered,
                lines: acceptedLines
              ) else {
            return PhotoReconstructionResult(
                image: image,
                inlinedBlockIDs: [],
                unresolvedBlockIDs: Set(blocks.map(\.id))
            )
        }
        return PhotoReconstructionResult(
            image: UIImage(cgImage: output, scale: image.scale, orientation: .up),
            inlinedBlockIDs: inlined,
            unresolvedBlockIDs: unresolved
        )
    }

    private struct LinePatch {
        let background: CIImage
        let text: CIImage
    }

    private func makePatch(
        source: CIImage,
        line: RecognizedTextLine,
        translation: String,
        extent: CGRect
    ) throws -> LinePatch? {
        try Task.checkCancellation()
        let points = ciPoints(for: line.quad, extent: extent)
        guard let correction = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        correction.setValue(source, forKey: kCIInputImageKey)
        correction.setValue(CIVector(cgPoint: points.topLeft), forKey: "inputTopLeft")
        correction.setValue(CIVector(cgPoint: points.topRight), forKey: "inputTopRight")
        correction.setValue(CIVector(cgPoint: points.bottomRight), forKey: "inputBottomRight")
        correction.setValue(CIVector(cgPoint: points.bottomLeft), forKey: "inputBottomLeft")
        guard let rectified = correction.outputImage,
              rectified.extent.width >= 8, rectified.extent.height >= 8,
              let rectifiedCG = context.createCGImage(rectified, from: rectified.extent),
              let erased = try ConservativeGlyphMask.makePatch(from: rectifiedCG),
              let textCG = TranslationLineLayout.draw(
                translation,
                size: CGSize(width: rectifiedCG.width, height: rectifiedCG.height),
                color: erased.foreground
              ) else {
            return nil
        }

        guard let background = perspectiveImage(
            erased.image,
            topLeft: points.topLeft,
            topRight: points.topRight,
            bottomRight: points.bottomRight,
            bottomLeft: points.bottomLeft,
            crop: extent
        ), let text = perspectiveImage(
            textCG,
            topLeft: points.topLeft,
            topRight: points.topRight,
            bottomRight: points.bottomRight,
            bottomLeft: points.bottomLeft,
            crop: extent
        ) else {
            return nil
        }
        return LinePatch(background: background, text: text)
    }

    static func copyOriginalPixelsOutsideLines(
        original: CGImage,
        rendered: CGImage,
        lines: [RecognizedTextLine]
    ) -> CGImage? {
        let width = original.width
        let height = original.height
        guard rendered.width == width, rendered.height == height else { return nil }
        let colorSpace = original.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let output = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        output.interpolationQuality = .none
        output.draw(original, in: bounds)
        guard !lines.isEmpty else { return output.makeImage() }

        // 从原图缓冲区出发，只在已接受的文字四边形内画合成图。这样区域外
        // 像素根本不会经过 Core Image 的颜色转换或重采样。
        for line in lines {
            let points = [
                line.quad.topLeft,
                line.quad.topRight,
                line.quad.bottomRight,
                line.quad.bottomLeft,
            ].map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
            let path = CGMutablePath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
            output.saveGState()
            output.addPath(path)
            output.clip()
            output.draw(rendered, in: bounds)
            output.restoreGState()
        }
        return output.makeImage()
    }

    private func perspectiveImage(
        _ image: CGImage,
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomRight: CGPoint,
        bottomLeft: CGPoint,
        crop: CGRect
    ) -> CIImage? {
        guard let transform = CIFilter(name: "CIPerspectiveTransform") else { return nil }
        transform.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        transform.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        transform.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        transform.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        transform.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        return transform.outputImage?.cropped(to: crop)
    }

    private func ciPoints(for quad: TextQuad, extent: CGRect) -> (
        topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint
    ) {
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(
                x: extent.minX + normalized.x * extent.width,
                y: extent.minY + normalized.y * extent.height
            )
        }
        return (
            point(quad.topLeft), point(quad.topRight),
            point(quad.bottomRight), point(quad.bottomLeft)
        )
    }
}

private enum ConservativeGlyphMask {
    struct Patch {
        let image: CGImage
        let foreground: UIColor
    }

    /// 这个阈值来自 0...1 RGB 方差。平面纸张与招牌通常低于 0.006，木纹、阴影和
    /// 渐变会高于它；高纹理区域保留原图。
    private static let maximumBorderVariance = 0.006
    /// 掩码太少通常只是噪点，太多则说明框内不是“底色 + 字形”。两边都宁可保留
    /// 原图和可点按卡片，也不冒险把招牌纹理当文字抹掉。
    private static let minimumInkCoverage = 0.008
    private static let maximumInkCoverage = 0.42

    static func makePatch(from image: CGImage) throws -> Patch? {
        try Task.checkCancellation()
        let width = image.width
        let height = image.height
        guard width >= 8, height >= 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drewImage = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        let border = borderIndices(width: width, height: height)
        let background = meanColor(indices: border, pixels: pixels)
        let variance = border.reduce(0.0) { partial, index in
            let color = rgb(at: index, pixels: pixels)
            return partial + squaredDistance(color, background)
        } / Double(max(border.count, 1))
        guard variance <= maximumBorderVariance else { return nil }

        // 平底至少要有 7.5% RGB 距离才算字形；带轻微光照变化时再按边缘噪声
        // 放大 3.5 倍，避免把渐变一起擦掉。
        let threshold = max(0.075, sqrt(variance) * 3.5)
        var mask = [Bool](repeating: false, count: width * height)
        var inkColors: [(Double, Double, Double)] = []
        for index in mask.indices {
            if index.isMultiple(of: width * 16) { try Task.checkCancellation() }
            let color = rgb(at: index, pixels: pixels)
            if sqrt(squaredDistance(color, background)) >= threshold {
                mask[index] = true
                inkColors.append(color)
            }
        }
        let coverage = Double(mask.filter { $0 }.count) / Double(mask.count)
        guard coverage >= minimumInkCoverage, coverage <= maximumInkCoverage else { return nil }

        let expanded = try feathered(mask: mask, width: width, height: height)
        var output = [UInt8](repeating: 0, count: pixels.count)
        let red = UInt8((background.0 * 255).rounded())
        let green = UInt8((background.1 * 255).rounded())
        let blue = UInt8((background.2 * 255).rounded())
        for index in mask.indices {
            let offset = index * 4
            let alpha = expanded[index]
            output[offset] = UInt8(UInt16(red) * UInt16(alpha) / 255)
            output[offset + 1] = UInt8(UInt16(green) * UInt16(alpha) / 255)
            output[offset + 2] = UInt8(UInt16(blue) * UInt16(alpha) / 255)
            output[offset + 3] = alpha
        }
        let patch = output.withUnsafeMutableBytes { raw -> CGImage? in
            guard let patchContext = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return patchContext.makeImage()
        }
        guard let patch else { return nil }

        let ink = inkColors.isEmpty ? contrastColor(for: background) : mean(inkColors)
        let foreground = UIColor(red: ink.0, green: ink.1, blue: ink.2, alpha: 1)
        return Patch(image: patch, foreground: foreground)
    }

    private static func borderIndices(width: Int, height: Int) -> [Int] {
        var indices: [Int] = []
        for y in 0..<height {
            for x in 0..<width where x < 2 || y < 2 || x >= width - 2 || y >= height - 2 {
                indices.append(y * width + x)
            }
        }
        return indices
    }

    private static func rgb(at index: Int, pixels: [UInt8]) -> (Double, Double, Double) {
        let offset = index * 4
        return (
            Double(pixels[offset]) / 255,
            Double(pixels[offset + 1]) / 255,
            Double(pixels[offset + 2]) / 255
        )
    }

    private static func meanColor(
        indices: [Int], pixels: [UInt8]
    ) -> (Double, Double, Double) {
        let colors = indices.map { rgb(at: $0, pixels: pixels) }
        return mean(colors)
    }

    private static func mean(_ values: [(Double, Double, Double)]) -> (Double, Double, Double) {
        let count = Double(max(values.count, 1))
        return values.reduce((0.0, 0.0, 0.0)) {
            ($0.0 + $1.0 / count, $0.1 + $1.1 / count, $0.2 + $1.2 / count)
        }
    }

    private static func squaredDistance(
        _ lhs: (Double, Double, Double), _ rhs: (Double, Double, Double)
    ) -> Double {
        let red = lhs.0 - rhs.0
        let green = lhs.1 - rhs.1
        let blue = lhs.2 - rhs.2
        return (red * red + green * green + blue * blue) / 3
    }

    private static func contrastColor(
        for color: (Double, Double, Double)
    ) -> (Double, Double, Double) {
        let luminance = 0.2126 * color.0 + 0.7152 * color.1 + 0.0722 * color.2
        return luminance > 0.5 ? (0.05, 0.05, 0.05) : (0.96, 0.96, 0.96)
    }

    private static func feathered(
        mask: [Bool], width: Int, height: Int
    ) throws -> [UInt8] {
        var alpha = [UInt8](repeating: 0, count: mask.count)
        for y in 0..<height {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            for x in 0..<width {
                let index = y * width + x
                if mask[index] {
                    alpha[index] = 255
                    continue
                }
                var touchesInk = false
                for offsetY in -1...1 {
                    for offsetX in -1...1 {
                        let sampleX = x + offsetX
                        let sampleY = y + offsetY
                        guard sampleX >= 0, sampleX < width,
                              sampleY >= 0, sampleY < height else { continue }
                        touchesInk = touchesInk || mask[sampleY * width + sampleX]
                    }
                }
                if touchesInk { alpha[index] = 128 }
            }
        }
        return alpha
    }
}

private enum TranslationLineLayout {
    static func segments(text: String, count: Int) -> [String]? {
        guard count > 0 else { return nil }
        if count == 1 { return [text] }
        let tokens = TextTokenization.ranges(in: text).map(\.text)
        guard tokens.count >= count else { return nil }
        let target = max(1, text.count / count)
        var result: [String] = []
        var current = ""
        for token in tokens {
            let candidate = current.isEmpty ? token : TextBlockGrouping.join(current, token)
            if !current.isEmpty, result.count < count - 1,
               candidate.count > target {
                result.append(current)
                current = token
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        guard result.count == count else { return nil }
        return result
    }

    static func draw(_ text: String, size: CGSize, color: UIColor) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        // 译文字高先贴近原行，但若为塞进原框而必须缩到行高 55% 以下，就放弃内嵌，
        // 交给可点按卡片显示；硬塞进去会得到“技术上画了、肉眼读不出”的假成功。
        let maximum = size.height * 0.74
        let minimum = size.height * 0.55
        let baseFont = UIFont.systemFont(ofSize: maximum, weight: .medium)
        let measured = (text as NSString).size(withAttributes: [.font: baseFont]).width
        let scale = min(1, (size.width * 0.96) / max(measured, 1))
        let fontSize = maximum * scale
        guard fontSize >= minimum else { return nil }

        let width = max(1, Int(size.width.rounded(.up)))
        let height = max(1, Int(size.height.rounded(.up)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: color,
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            context.textPosition = CGPoint(
                x: max(0, (CGFloat(width) - bounds.width) / 2 - bounds.minX),
                y: max(0, (CGFloat(height) - bounds.height) / 2 - bounds.minY)
            )
            CTLineDraw(line, context)
            return context.makeImage()
        }
    }
}

struct TranslatedPhotoCanvas: UIViewRepresentable {
    struct Actions {
        let translateSelection: (String) async -> Result<String, TranslationError>
        let speak: (String, Bool) -> Void
        let save: (String, String) -> Void
        let retryBlock: (UUID) -> Void
    }

    let image: UIImage
    let translatedImage: UIImage?
    let blocks: [PhotoTranslationController.TranslatedBlock]
    let mode: PhotoDisplayMode
    let actions: Actions

    func makeUIView(context: Context) -> TranslatedPhotoCanvasView {
        let view = TranslatedPhotoCanvasView()
        view.accessibilityIdentifier = "camera.resultCanvas"
        return view
    }

    func updateUIView(_ view: TranslatedPhotoCanvasView, context: Context) {
        view.configure(
            originalImage: image,
            translatedImage: translatedImage,
            blocks: blocks,
            mode: mode,
            actions: actions
        )
    }
}

@MainActor
final class TranslatedPhotoCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let imageView = UIImageView()
    private let highlightLayer = CAShapeLayer()
    private let startHandle = SelectionHandleView(label: String(localized: "选择起点"))
    private let endHandle = SelectionHandleView(label: String(localized: "选择终点"))
    private let card = PhotoSelectionCardView()
    private var originalImage: UIImage?
    private var translatedImage: UIImage?
    private var blocks: [PhotoTranslationController.TranslatedBlock] = []
    private var mode: PhotoDisplayMode = .translation
    private var actions: TranslatedPhotoCanvas.Actions?
    private var selection: ClosedRange<Int>?
    /// 长按拖选的起点必须跨整个手势保持不变；不能从每次更新后的 range 反推，
    /// 否则向左跨过多个词时会逐步丢掉最初按住的那个词。
    private var longPressAnchorIndex: Int?
    private var selectionRevision = 0
    private var canvasSize = CGSize.zero
    private var didSetInitialGeometry = false

    private lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
    private lazy var longPressGesture: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress(_:)))
        gesture.minimumPressDuration = 0.42
        gesture.allowableMovement = 10
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scrollView.delegate = self
        scrollView.maximumZoomScale = 5
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        imageView.contentMode = .scaleToFill
        imageView.isAccessibilityElement = false
        contentView.addSubview(imageView)
        highlightLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.24).cgColor
        highlightLayer.strokeColor = UIColor.systemBlue.cgColor
        highlightLayer.lineWidth = 1.5
        contentView.layer.addSublayer(highlightLayer)
        contentView.addSubview(startHandle)
        contentView.addSubview(endHandle)
        startHandle.onMove = { [weak self] point in self?.moveHandle(start: true, to: point) }
        endHandle.onMove = { [weak self] point in self?.moveHandle(start: false, to: point) }
        startHandle.onEnd = { [weak self] in self?.translateCurrentSelection() }
        endHandle.onEnd = { [weak self] in self?.translateCurrentSelection() }
        startHandle.accessibilityIdentifier = "camera.selectionHandle.start"
        endHandle.accessibilityIdentifier = "camera.selectionHandle.end"
        startHandle.onAdjust = { [weak self] direction in self?.adjustHandle(start: true, direction: direction) }
        endHandle.onAdjust = { [weak self] direction in self?.adjustHandle(start: false, direction: direction) }
        startHandle.isHidden = true
        endHandle.isHidden = true
        addSubview(card)
        card.isHidden = true
        card.onClose = { [weak self] in self?.clearSelection() }
        card.onCopy = { text in UIPasteboard.general.string = text }
        card.onSpeak = { [weak self] text, translated in self?.actions?.speak(text, translated) }
        card.onSave = { [weak self] source, translation in self?.actions?.save(source, translation) }
        card.onRetryBlock = { [weak self] id in self?.actions?.retryBlock(id) }
        card.onRetrySelection = { [weak self] text in self?.translateSelection(text) }

        tapGesture.delegate = self
        tapGesture.require(toFail: scrollView.panGestureRecognizer)
        if let pinch = scrollView.pinchGestureRecognizer { tapGesture.require(toFail: pinch) }
        contentView.addGestureRecognizer(tapGesture)
        contentView.addGestureRecognizer(longPressGesture)
        scrollView.panGestureRecognizer.require(toFail: longPressGesture)
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        originalImage: UIImage,
        translatedImage: UIImage?,
        blocks: [PhotoTranslationController.TranslatedBlock],
        mode: PhotoDisplayMode,
        actions: TranslatedPhotoCanvas.Actions
    ) {
        let imageChanged = self.originalImage !== originalImage
        let finalImageArrived = !imageChanged
            && self.translatedImage == nil
            && translatedImage != nil
            && mode == .translation
        self.originalImage = originalImage
        self.translatedImage = translatedImage
        self.blocks = blocks
        self.actions = actions
        card.refreshPresentedBlock(from: blocks)
        if self.mode != mode {
            self.mode = mode
            clearSelection()
        }
        let displayedImage = mode == .original ? originalImage : (translatedImage ?? originalImage)
        if finalImageArrived {
            UIView.transition(
                with: imageView,
                duration: 0.18,
                options: [.transitionCrossDissolve, .allowAnimatedContent]
            ) {
                self.imageView.image = displayedImage
            }
        } else {
            imageView.image = displayedImage
        }
        if imageChanged {
            didSetInitialGeometry = false
            setNeedsLayout()
        }
        rebuildAccessibilityElements()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard let image = originalImage else { return }
        let nextCanvas = OverlayGeometry.aspectFillSize(imageSize: image.size, in: bounds.size)
        if nextCanvas != canvasSize {
            let preservedScale = scrollView.zoomScale
            let preservedCenter = CGPoint(
                x: scrollView.contentOffset.x + bounds.width / 2,
                y: scrollView.contentOffset.y + bounds.height / 2
            )
            canvasSize = nextCanvas
            scrollView.zoomScale = 1
            contentView.frame = CGRect(origin: .zero, size: canvasSize)
            imageView.frame = contentView.bounds
            highlightLayer.frame = contentView.bounds
            scrollView.contentSize = canvasSize
            let minimum = OverlayGeometry.minimumZoomScale(
                canvasSize: canvasSize, viewportSize: bounds.size
            )
            scrollView.minimumZoomScale = minimum
            scrollView.contentInset = UIEdgeInsets(
                top: bounds.height / 2,
                left: bounds.width / 2,
                bottom: bounds.height / 2,
                right: bounds.width / 2
            )
            if didSetInitialGeometry {
                scrollView.zoomScale = min(max(preservedScale, minimum), 5)
                scrollView.contentOffset = CGPoint(
                    x: preservedCenter.x - bounds.width / 2,
                    y: preservedCenter.y - bounds.height / 2
                )
            } else {
                let imageIsLandscape = canvasSize.width > canvasSize.height
                let viewportIsLandscape = bounds.width > bounds.height
                let initial = imageIsLandscape == viewportIsLandscape ? 1 : minimum
                scrollView.zoomScale = initial
                scrollView.contentOffset = CGPoint(
                    x: (canvasSize.width * initial - bounds.width) / 2,
                    y: (canvasSize.height * initial - bounds.height) / 2
                )
                didSetInitialGeometry = true
            }
            updateSelectionAppearance()
            rebuildAccessibilityElements()
        }
        let cardHeight = min(218, max(170, bounds.height * 0.28))
        card.frame = CGRect(
            x: 14,
            y: bounds.height - cardHeight - safeAreaInsets.bottom - 12,
            width: bounds.width - 28,
            height: cardHeight
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { rebuildAccessibilityElements() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { rebuildAccessibilityElements() }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        if abs(scale - scrollView.minimumZoomScale) < 0.02 {
            scrollView.contentOffset = CGPoint(
                x: (canvasSize.width * scale - bounds.width) / 2,
                y: (canvasSize.height * scale - bounds.height) / 2
            )
        }
        rebuildAccessibilityElements()
    }

    private var orderedTokens: [(token: RecognizedTextToken, blockID: UUID)] {
        blocks.flatMap { block in block.tokens.map { ($0, block.id) } }
    }

    @objc private func didTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: contentView)
        if mode == .translation {
            guard let block = block(at: point) else { clearSelection(); return }
            selection = nil
            updateSelectionAppearance()
            card.show(block: block)
            rebuildAccessibilityElements()
            return
        }
        guard let index = tokenIndex(at: point) else { clearSelection(); return }
        select(index...index, translate: true)
    }

    @objc private func didLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard mode == .original else { return }
        let point = gesture.location(in: contentView)
        guard let index = tokenIndex(at: point) ?? nearestTokenIndex(to: point) else { return }
        switch gesture.state {
        case .began:
            longPressAnchorIndex = index
            select(index...index, translate: false)
        case .changed:
            guard let anchor = longPressAnchorIndex else { return }
            select(Self.selectionRange(anchor: anchor, current: index), translate: false)
        case .ended, .cancelled:
            longPressAnchorIndex = nil
            translateCurrentSelection()
        default:
            longPressAnchorIndex = nil
            break
        }
    }

    private func select(_ range: ClosedRange<Int>, translate: Bool) {
        selection = range
        updateSelectionAppearance()
        let text = selectedText(in: range)
        card.showSelection(source: text)
        rebuildAccessibilityElements()
        if translate { translateSelection(text) }
    }

    private func translateCurrentSelection() {
        guard let selection else { return }
        translateSelection(selectedText(in: selection))
    }

    private func translateSelection(_ text: String) {
        guard let translate = actions?.translateSelection else { return }
        selectionRevision += 1
        let revision = selectionRevision
        card.showSelection(source: text)
        Task { [weak self] in
            let result = await translate(text)
            guard let self, revision == self.selectionRevision else { return }
            card.finishSelection(result)
        }
    }

    private func selectedText(in range: ClosedRange<Int>) -> String {
        let tokens = orderedTokens
        return Self.joinSelectedTokenTexts(
            range.compactMap { tokens.indices.contains($0) ? tokens[$0].token.text : nil }
        )
    }

    static func selectionRange(anchor: Int, current: Int) -> ClosedRange<Int> {
        min(anchor, current)...max(anchor, current)
    }

    static func joinSelectedTokenTexts(_ texts: [String]) -> String {
        texts.reduce(into: "") { joined, text in
            joined = joined.isEmpty ? text : TextBlockGrouping.join(joined, text)
        }
    }

    private func block(at point: CGPoint) -> PhotoTranslationController.TranslatedBlock? {
        let rect = CGRect(origin: .zero, size: canvasSize)
        return blocks.reversed().first { block in
            let placement = OverlayGeometry.place(block.quad, in: rect)
            return OverlayGeometry.contains(
                point,
                inRotatedRectAt: placement.center,
                size: placement.size,
                angle: placement.angle
            )
        }
    }

    private func tokenIndex(at point: CGPoint) -> Int? {
        let rect = CGRect(origin: .zero, size: canvasSize)
        return orderedTokens.indices.reversed().first { index in
            let placement = OverlayGeometry.place(orderedTokens[index].token.quad, in: rect)
            return OverlayGeometry.contains(
                point,
                inRotatedRectAt: placement.center,
                size: CGSize(
                    width: max(placement.size.width, 18 / max(scrollView.zoomScale, 0.1)),
                    height: max(placement.size.height, 18 / max(scrollView.zoomScale, 0.1))
                ),
                angle: placement.angle
            )
        }
    }

    private func nearestTokenIndex(to point: CGPoint) -> Int? {
        let rect = CGRect(origin: .zero, size: canvasSize)
        return orderedTokens.indices.min { lhs, rhs in
            let left = OverlayGeometry.place(orderedTokens[lhs].token.quad, in: rect).center
            let right = OverlayGeometry.place(orderedTokens[rhs].token.quad, in: rect).center
            return hypot(left.x - point.x, left.y - point.y)
                < hypot(right.x - point.x, right.y - point.y)
        }
    }

    private func moveHandle(start: Bool, to point: CGPoint) {
        guard let selection, let index = nearestTokenIndex(to: point) else { return }
        let range = start
            ? min(index, selection.upperBound)...selection.upperBound
            : selection.lowerBound...max(index, selection.lowerBound)
        select(range, translate: false)
    }

    private func adjustHandle(start: Bool, direction: UIAccessibilityScrollDirection) {
        guard let selection else { return }
        let count = orderedTokens.count
        let delta = direction == .right || direction == .down ? 1 : -1
        if start {
            let next = min(max(0, selection.lowerBound + delta), selection.upperBound)
            select(next...selection.upperBound, translate: true)
        } else {
            let next = min(max(selection.lowerBound, selection.upperBound + delta), max(0, count - 1))
            select(selection.lowerBound...next, translate: true)
        }
    }

    private func clearSelection() {
        selectionRevision += 1
        selection = nil
        longPressAnchorIndex = nil
        card.dismiss()
        updateSelectionAppearance()
        rebuildAccessibilityElements()
    }

    private func updateSelectionAppearance() {
        guard let selection else {
            highlightLayer.path = nil
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let tokens = orderedTokens
        let rect = CGRect(origin: .zero, size: canvasSize)
        let path = UIBezierPath()
        for index in selection where tokens.indices.contains(index) {
            let quad = tokens[index].token.quad
            path.move(to: OverlayGeometry.point(quad.topLeft, in: rect))
            path.addLine(to: OverlayGeometry.point(quad.topRight, in: rect))
            path.addLine(to: OverlayGeometry.point(quad.bottomRight, in: rect))
            path.addLine(to: OverlayGeometry.point(quad.bottomLeft, in: rect))
            path.close()
        }
        highlightLayer.path = path.cgPath
        guard tokens.indices.contains(selection.lowerBound),
              tokens.indices.contains(selection.upperBound) else { return }
        startHandle.center = OverlayGeometry.point(
            tokens[selection.lowerBound].token.quad.bottomLeft,
            in: rect
        )
        endHandle.center = OverlayGeometry.point(
            tokens[selection.upperBound].token.quad.bottomRight,
            in: rect
        )
        startHandle.isHidden = false
        endHandle.isHidden = false
    }

    private func rebuildAccessibilityElements() {
        let rect = CGRect(origin: .zero, size: canvasSize)
        let items: [CanvasAccessibilityElement]
        if mode == .translation {
            items = blocks.enumerated().map { index, block in
                let element = CanvasAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = block.source
                element.accessibilityValue = block.displayText
                element.accessibilityTraits = .button
                element.accessibilityIdentifier = "camera.block.\(index)"
                element.accessibilityFrameInContainerSpace = contentView.convert(
                    OverlayGeometry.place(block.quad, in: rect).boundingRect,
                    to: self
                )
                element.onActivate = { [weak self] in
                    self?.card.show(block: block)
                    return true
                }
                return element
            }
        } else {
            items = orderedTokens.enumerated().map { index, item in
                let element = CanvasAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = item.token.text
                element.accessibilityTraits = .button
                element.accessibilityIdentifier = "camera.token.\(index)"
                element.accessibilityFrameInContainerSpace = contentView.convert(
                    OverlayGeometry.place(item.token.quad, in: rect).boundingRect,
                    to: self
                )
                element.onActivate = { [weak self] in
                    self?.select(index...index, translate: true)
                    return true
                }
                return element
            }
        }
        var visibleExtras: [Any] = []
        if !startHandle.isHidden { visibleExtras.append(startHandle) }
        if !endHandle.isHidden { visibleExtras.append(endHandle) }
        if !card.isHidden { visibleExtras.append(card) }
        accessibilityElements = items.map { $0 as Any } + visibleExtras
    }
}

private extension OverlayGeometry.Placement {
    var boundingRect: CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
private final class CanvasAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { onActivate?() ?? false }
}

@MainActor
final class SelectionHandleView: UIView {
    var onMove: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onAdjust: ((UIAccessibilityScrollDirection) -> Void)?

    init(label: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        backgroundColor = .systemBlue
        layer.cornerRadius = 14
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = [.adjustable]
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
        processPan(state: gesture.state, location: gesture.location(in: superview))
    }

    func processPan(state: UIGestureRecognizer.State, location: CGPoint) {
        switch state {
        case .began, .changed:
            onMove?(location)
        case .ended, .cancelled:
            onEnd?()
        default:
            break
        }
    }

    override func accessibilityIncrement() { onAdjust?(.right) }
    override func accessibilityDecrement() { onAdjust?(.left) }
}

@MainActor
private final class PhotoSelectionCardView: UIVisualEffectView {
    private static let fallbackError = String(localized: "翻译失败，请重试")

    private let sourceLabel = UILabel()
    private let translationLabel = UILabel()
    private let buttonStack = UIStackView()
    private var source = ""
    private var translation = ""
    private var blockID: UUID?
    private var failure: TranslationError?
    var onClose: (() -> Void)?
    var onCopy: ((String) -> Void)?
    var onSpeak: ((String, Bool) -> Void)?
    var onSave: ((String, String) -> Void)?
    var onRetryBlock: ((UUID) -> Void)?
    var onRetrySelection: ((String) -> Void)?

    private lazy var copyButton = button("doc.on.doc", action: #selector(copyText))
    private lazy var speakButton = button("speaker.wave.2", action: #selector(speakText))
    private lazy var saveButton = button("clock.arrow.circlepath", action: #selector(saveText))
    private lazy var retryButton = button("arrow.clockwise", action: #selector(retry))
    private lazy var closeButton = button("xmark", action: #selector(close))

    init() {
        super.init(effect: UIBlurEffect(style: .systemChromeMaterial))
        layer.cornerRadius = 24
        clipsToBounds = true
        accessibilityIdentifier = "camera.selectionCard"
        let textStack = UIStackView(arrangedSubviews: [sourceLabel, translationLabel])
        textStack.axis = .vertical
        textStack.spacing = 8
        sourceLabel.font = .systemFont(ofSize: 15, weight: .medium)
        sourceLabel.textColor = .secondaryLabel
        sourceLabel.numberOfLines = 2
        sourceLabel.accessibilityIdentifier = "camera.selectionCard.source"
        translationLabel.font = .systemFont(ofSize: 19, weight: .regular)
        translationLabel.numberOfLines = 3
        translationLabel.accessibilityIdentifier = "camera.selectionCard.translation"
        buttonStack.axis = .horizontal
        buttonStack.spacing = 16
        copyButton.accessibilityLabel = String(localized: "复制译文")
        copyButton.accessibilityIdentifier = "camera.selectionCard.copy"
        speakButton.accessibilityLabel = String(localized: "朗读译文")
        speakButton.accessibilityIdentifier = "camera.selectionCard.speak"
        saveButton.accessibilityLabel = String(localized: "存入历史记录")
        saveButton.accessibilityIdentifier = "camera.selectionCard.save"
        retryButton.accessibilityLabel = String(localized: "重试")
        retryButton.accessibilityIdentifier = "camera.selectionCard.retry"
        closeButton.accessibilityLabel = String(localized: "关闭")
        closeButton.accessibilityIdentifier = "camera.selectionCard.close"
        [copyButton, speakButton, saveButton, retryButton, closeButton].forEach {
            buttonStack.addArrangedSubview($0)
        }
        let stack = UIStackView(arrangedSubviews: [textStack, buttonStack])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(block: PhotoTranslationController.TranslatedBlock) {
        source = block.source
        translation = block.translation
        blockID = block.id
        failure = block.failure
        sourceLabel.text = block.source
        if let failure = block.failure {
            translationLabel.text = failure.errorDescription ?? Self.fallbackError
        } else if block.isPending {
            translationLabel.text = String(localized: "正在翻译…")
        } else {
            translationLabel.text = block.translation
        }
        applyState()
        isHidden = false
    }

    func showSelection(source: String) {
        self.source = source
        translation = ""
        blockID = nil
        failure = nil
        sourceLabel.text = source
        translationLabel.text = String(localized: "正在翻译…")
        applyState()
        isHidden = false
    }

    func refreshPresentedBlock(
        from blocks: [PhotoTranslationController.TranslatedBlock]
    ) {
        guard let blockID else { return }
        guard let block = blocks.first(where: { $0.id == blockID }) else {
            dismiss()
            return
        }
        show(block: block)
    }

    func dismiss() {
        blockID = nil
        failure = nil
        isHidden = true
    }

    func finishSelection(_ result: Result<String, TranslationError>) {
        switch result {
        case .success(let text):
            translation = text
            failure = nil
            translationLabel.text = text
        case .failure(let error):
            translation = ""
            failure = error
            translationLabel.text = error.errorDescription ?? Self.fallbackError
        }
        applyState()
    }

    private func applyState() {
        let hasTranslation = !translation.isEmpty && failure == nil
        copyButton.isEnabled = hasTranslation
        speakButton.isEnabled = hasTranslation
        saveButton.isEnabled = hasTranslation
        retryButton.isHidden = failure == nil
    }

    private func button(_ systemName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func copyText() { onCopy?(translation.isEmpty ? source : translation) }
    @objc private func speakText() { onSpeak?(translation.isEmpty ? source : translation, !translation.isEmpty) }
    @objc private func saveText() { onSave?(source, translation) }
    @objc private func retry() {
        if let blockID { onRetryBlock?(blockID) } else { onRetrySelection?(source) }
    }
    @objc private func close() { onClose?() }
}
