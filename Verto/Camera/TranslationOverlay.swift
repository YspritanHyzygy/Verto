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
import SwiftUI
import UIKit

/// 归一化文字块 → 视图坐标。纯函数，无 SwiftUI 依赖，便于单测。
enum OverlayGeometry {
    struct Placement: Equatable {
        /// 块中心（视图坐标）。
        var center: CGPoint
        /// 沿基线的宽 × 垂直基线的高。
        var size: CGSize
        /// 视图坐标下的倾角（顺时针为正）。
        var angle: Angle
    }

    /// `.aspectFill` 后的真实画布尺寸。画布可能大于视口，图片和贴片共用它，
    /// 所以拖动时不会出现照片走了、贴片还钉在屏幕上的两套坐标。
    static func aspectFillSize(imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = max(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    /// 结果默认以 1× 的 aspectFill 构图出现，但用户继续缩小时必须能看到整张照片。
    /// 这个比例正好把 aspectFill 画布退回 aspectFit；不允许大于 1，避免小画布被反向放大。
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

    /// Vision 归一化点（原点左下、y 向上）→ 视图点（原点左上、y 向下）。
    static func point(_ normalized: CGPoint, in displayRect: CGRect) -> CGPoint {
        CGPoint(
            x: displayRect.minX + normalized.x * displayRect.width,
            y: displayRect.minY + (1 - normalized.y) * displayRect.height
        )
    }

    /// 先把四角各自换算到视图坐标再取角度，**不要**先算 Vision 角再手工取负：
    /// y 轴翻转对角度的影响由坐标换算自然带出，手工取负在非等比缩放下还会错。
    static func place(_ quad: TextQuad, in displayRect: CGRect) -> Placement {
        let topLeft = point(quad.topLeft, in: displayRect)
        let topRight = point(quad.topRight, in: displayRect)
        let bottomLeft = point(quad.bottomLeft, in: displayRect)
        let bottomRight = point(quad.bottomRight, in: displayRect)

        let center = CGPoint(
            x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4,
            y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4
        )
        let width = max(hypot(topRight.x - topLeft.x, topRight.y - topLeft.y),
                        hypot(bottomRight.x - bottomLeft.x, bottomRight.y - bottomLeft.y))
        let height = max(hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y),
                         hypot(bottomRight.x - topRight.x, bottomRight.y - topRight.y))
        let angle = atan2(topRight.y - topLeft.y, topRight.x - topLeft.x)

        return Placement(
            center: center,
            size: CGSize(width: width, height: height),
            angle: .radians(Double(angle))
        )
    }

    /// 把触点旋回贴片自己的坐标系后判断是否落在框内。译文框可以随原文倾斜，
    /// 只拿轴对齐包围盒判定会让框外四个角也莫名其妙可点。
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

/// 一块文字从原图上采到的配色：底色用来盖掉原文，字色用来写译文。
struct BlockPalette: Equatable {
    var background: Color
    var foreground: Color

    /// 采样失败（图太小、块退化）时的保底：中性深底白字，任何照片上都可读。
    static let fallback = BlockPalette(
        background: Color(white: 0.12),
        foreground: Color(white: 0.97)
    )
}

/// 从原图采底色与字色——译文贴片看起来"长在照片里"而不是"贴在照片上"，
/// 全靠这两个颜色取自原文本身。
enum ImageColorSampler {
    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double

        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

        func distance(to other: RGB) -> Double {
            let dr = red - other.red, dg = green - other.green, db = blue - other.blue
            return dr * dr + dg * dg + db * db
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    }

    /// 采样网格边长。取 48 而非更小：细笔画（小字号、瘦体）在粗网格里会被整格
    /// 漏掉，纯底色格子占压倒多数，字色就被稀释成灰的；再大则纯属浪费。
    private static let gridSize = 48
    /// 采样区在文字框外扩的比例（按框高算）。外扩才能吃到文字周围的底色；
    /// 0.3 够覆盖常见的字距留白，又不至于吃进隔壁那块文字。
    private static let padRatio: CGFloat = 0.3
    /// 字色取"与底色距离达到本块最大距离这个比例"的那批像素求均值。
    ///
    /// 用相对阈值而不是固定分位数：固定分位数（如最远的 15%）在细笔画块上必然
    /// 吃进大量底色格，均值被拉回灰色——实测同一张牌子上粗体行字色正确、
    /// 细体行发灰就是这么来的。相对阈值只收真正接近最深的那批，笔画粗细都成立。
    private static let inkDistanceRatio = 0.5
    /// 底色与字色的最小色距平方。低于它说明这块根本没采出对比
    /// （纯色区域、过曝），退回保底配色而不是画一块看不见的字。
    private static let minimumContrast = 0.02

    static func palette(for quad: TextQuad, in image: CGImage) -> BlockPalette {
        let box = quad.boundingBox
        guard box.width > 0, box.height > 0 else { return .fallback }

        let pad = box.height * padRatio
        let padded = box.insetBy(dx: -pad, dy: -pad)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !padded.isNull, padded.width > 0, padded.height > 0 else { return .fallback }

        // Vision 原点在左下，CGImage 裁剪坐标原点在左上：翻 y。
        let pixelRect = CGRect(
            x: padded.minX * CGFloat(image.width),
            y: (1 - padded.maxY) * CGFloat(image.height),
            width: padded.width * CGFloat(image.width),
            height: padded.height * CGFloat(image.height)
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = image.cropping(to: pixelRect),
              let pixels = samplePixels(of: cropped) else {
            return .fallback
        }

        let background = medianBorderColor(of: pixels)
        let foreground = inkColor(in: pixels, background: background)
        guard foreground.distance(to: background) >= minimumContrast else {
            // 采不出对比就按底色明暗给个高对比字色，至少保证可读。
            return BlockPalette(
                background: background.color,
                foreground: background.luminance > 0.5 ? Color(white: 0.08) : Color(white: 0.96)
            )
        }
        return BlockPalette(background: background.color, foreground: foreground.color)
    }

    /// 缩到固定网格读像素。插值必须关掉（`.none`）：双线性会把字和底混成
    /// 中间色，字色就永远采成灰的了。
    private static func samplePixels(of image: CGImage) -> [RGB]? {
        let side = gridSize
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let success = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard success else { return nil }

        return stride(from: 0, to: buffer.count, by: 4).map { offset in
            RGB(
                red: Double(buffer[offset]) / 255,
                green: Double(buffer[offset + 1]) / 255,
                blue: Double(buffer[offset + 2]) / 255
            )
        }
    }

    /// 底色 = 外圈一整圈像素的逐通道中位数。外扩区几乎全是底，
    /// 中位数对个别越界进来的笔画免疫。
    private static func medianBorderColor(of pixels: [RGB]) -> RGB {
        let side = gridSize
        var border: [RGB] = []
        for row in 0..<side {
            for column in 0..<side where row == 0 || row == side - 1 || column == 0 || column == side - 1 {
                border.append(pixels[row * side + column])
            }
        }
        guard !border.isEmpty else { return RGB(red: 0, green: 0, blue: 0) }
        return RGB(
            red: median(border.map(\.red)),
            green: median(border.map(\.green)),
            blue: median(border.map(\.blue))
        )
    }

    private static func inkColor(in pixels: [RGB], background: RGB) -> RGB {
        let distances = pixels.map { $0.distance(to: background) }
        guard let maxDistance = distances.max(), maxDistance > 0 else { return background }
        let threshold = maxDistance * inkDistanceRatio
        let ink = zip(pixels, distances).filter { $0.1 >= threshold }.map(\.0)
        guard !ink.isEmpty else { return background }
        let count = Double(ink.count)
        return RGB(
            red: ink.map(\.red).reduce(0, +) / count,
            green: ink.map(\.green).reduce(0, +) / count,
            blue: ink.map(\.blue).reduce(0, +) / count
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}

/// 照片 + 就地叠加的译文贴片。
struct TranslationOverlayView: View {
    let image: UIImage
    let blocks: [PhotoTranslationController.TranslatedBlock]
    let onSelect: (PhotoTranslationController.TranslatedBlock) -> Void

    @State private var palettes: [UUID: BlockPalette] = [:]

    var body: some View {
        GeometryReader { proxy in
            let canvasSize = OverlayGeometry.aspectFillSize(imageSize: image.size, in: proxy.size)
            let imageRect = CGRect(origin: .zero, size: canvasSize)

            ZoomableResultCanvas(
                canvasSize: canvasSize,
                viewportSize: proxy.size,
                onTap: { point in
                    // 后画的贴片在视觉上位于上层；若文字框重叠，点击也选同一块。
                    if let block = blocks.reversed().first(where: { block in
                        let placement = OverlayGeometry.place(block.quad, in: imageRect)
                        return TranslationBlockSticker.contains(
                            point,
                            block: block,
                            placement: placement
                        )
                    }) {
                        onSelect(block)
                    }
                }
            ) {
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .accessibilityHidden(true)

                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        TranslationBlockSticker(
                            block: block,
                            index: index,
                            placement: OverlayGeometry.place(block.quad, in: imageRect),
                            palette: palettes[block.id] ?? .fallback,
                            onTap: { onSelect(block) }
                        )
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
            }
        }
        .task(id: blocks.map(\.id)) {
            await loadPalettes()
        }
    }

    /// 取色只依赖图和块的位置，与译文填充无关——所以按块 id 集合触发一次即可，
    /// 译文陆续到达不会重算。
    private func loadPalettes() async {
        guard let cgImage = image.cgImage else { return }
        let quads = blocks.map { (id: $0.id, quad: $0.quad) }
        let sampled = await Task.detached(priority: .userInitiated) {
            var result: [UUID: BlockPalette] = [:]
            for entry in quads {
                result[entry.id] = ImageColorSampler.palette(for: entry.quad, in: cgImage)
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        palettes = sampled
    }
}

/// SwiftUI 的 `ScrollView` 与 `MagnifyGesture` 会互相抢识别器：能缩放后单指就拖不动，
/// 把两个手势合并又会丢掉连续捏合。这里让系统同一个 `UIScrollView` 同时负责两者，
/// 它承载的仍是上面的唯一一份真实照片与真实贴片，不创建截图或替身内容。
private struct ZoomableResultCanvas<Content: View>: UIViewRepresentable {
    let canvasSize: CGSize
    let viewportSize: CGSize
    let onTap: (CGPoint) -> Void
    let content: Content

    init(
        canvasSize: CGSize,
        viewportSize: CGSize,
        onTap: @escaping (CGPoint) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.canvasSize = canvasSize
        self.viewportSize = viewportSize
        self.onTap = onTap
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, onTap: onTap)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "camera.resultCanvas"

        // UIKit 的 tap 会等 pan / pinch 明确失败后才触发：框上拖动和双指缩放
        // 因而始终属于画布，只有几乎没位移的一指轻点才会进入译文详情。
        let tapGesture = context.coordinator.tapGesture
        tapGesture.require(toFail: scrollView.panGestureRecognizer)
        if let pinchGesture = scrollView.pinchGestureRecognizer {
            tapGesture.require(toFail: pinchGesture)
        }
        scrollView.addGestureRecognizer(tapGesture)

        let hostedView = context.coordinator.hostingController.view!
        hostedView.backgroundColor = .clear
        scrollView.addSubview(hostedView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTap = onTap
        coordinator.hostingController.rootView = content
        coordinator.hostingController.view.frame = CGRect(origin: .zero, size: canvasSize)
        scrollView.contentSize = canvasSize

        guard coordinator.canvasSize != canvasSize || coordinator.viewportSize != viewportSize else {
            return
        }
        coordinator.canvasSize = canvasSize
        coordinator.viewportSize = viewportSize

        // 1× 仍是与取景一致的 aspectFill 初始构图；最小倍率退到 aspectFit，
        // 所以用户可以缩到整张照片完整出现，而不是被 1× 硬挡住。
        scrollView.minimumZoomScale = OverlayGeometry.minimumZoomScale(
            canvasSize: canvasSize,
            viewportSize: viewportSize
        )

        // 每边留半屏，UIScrollView 自己的边界便正好是“照片任意边到屏幕中心”；
        // 关闭 bounce 后到这里就停，不会继续把画布拖进黑色虚空。
        scrollView.contentInset = UIEdgeInsets(
            top: viewportSize.height / 2,
            left: viewportSize.width / 2,
            bottom: viewportSize.height / 2,
            right: viewportSize.width / 2
        )
        scrollView.zoomScale = 1
        scrollView.contentOffset = CGPoint(
            x: (canvasSize.width - viewportSize.width) / 2,
            y: (canvasSize.height - viewportSize.height) / 2
        )
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.hostingController.view.removeFromSuperview()
        scrollView.delegate = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>
        lazy var tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
        var onTap: (CGPoint) -> Void
        var canvasSize: CGSize = .zero
        var viewportSize: CGSize = .zero

        init(content: Content, onTap: @escaping (CGPoint) -> Void) {
            hostingController = UIHostingController(rootView: content)
            self.onTap = onTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        @objc private func didTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onTap(gesture.location(in: hostingController.view))
        }
    }
}

private struct TranslationBlockSticker: View {
    let block: PhotoTranslationController.TranslatedBlock
    let index: Int
    let placement: OverlayGeometry.Placement
    let palette: BlockPalette
    let onTap: () -> Void

    /// 字号按单行高的这个比例起算（西文 cap height 约占行高七成半），
    /// 塞不下再由 minimumScaleFactor 收缩。
    private static let capHeightRatio: CGFloat = 0.74
    /// 贴片相对原文框的外扩量（按行高算）。原文的抗锯齿边缘会溢出 Vision 给的框，
    /// 不外扩会露出一圈原文的毛边。
    private static let coverInsetRatio: CGFloat = 0.16

    private var lineHeight: CGFloat {
        max(placement.size.height / CGFloat(max(block.lineCount, 1)), 1)
    }

    private var inset: CGFloat {
        lineHeight * Self.coverInsetRatio
    }

    static func contains(
        _ point: CGPoint,
        block: PhotoTranslationController.TranslatedBlock,
        placement: OverlayGeometry.Placement
    ) -> Bool {
        let lineHeight = max(placement.size.height / CGFloat(max(block.lineCount, 1)), 1)
        let inset = lineHeight * coverInsetRatio
        return OverlayGeometry.contains(
            point,
            inRotatedRectAt: placement.center,
            size: CGSize(
                width: placement.size.width + inset * 2,
                height: placement.size.height + inset * 2
            ),
            angle: placement.angle
        )
    }

    var body: some View {
        Text(block.displayText)
            .font(.system(size: lineHeight * Self.capHeightRatio, weight: .medium))
            .foregroundStyle(palette.foreground)
            .lineLimit(block.lineCount)
            .minimumScaleFactor(0.35)
            .multilineTextAlignment(.leading)
            .opacity(block.isPending ? 0.55 : 1)
            .frame(
                width: max(placement.size.width, 1),
                height: max(placement.size.height, 1),
                alignment: .leading
            )
            .padding(inset)
            .background(palette.background, in: RoundedRectangle(cornerRadius: inset * 2, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if block.failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: max(lineHeight * 0.42, 9), weight: .bold))
                        .foregroundStyle(AppTheme.alertOnPhoto)
                        .padding(inset * 0.5)
                }
            }
            .rotationEffect(placement.angle)
            .position(placement.center)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(block.source)
            .accessibilityValue(block.displayText)
            .accessibilityHint(String(localized: "轻点查看原文与译文对照"))
            .accessibilityAction { onTap() }
            .accessibilityIdentifier("camera.block.\(index)")
    }
}
