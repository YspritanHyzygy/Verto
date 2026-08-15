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

    /// `.scaledToFit` 之后图片实际占据的矩形。叠加块必须按这个矩形定位，
    /// 而不是容器尺寸——上下（或左右）的留白会让所有块整体偏移。
    static func displayRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return .zero
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
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
            let displayRect = OverlayGeometry.displayRect(imageSize: image.size, in: proxy.size)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityHidden(true)

                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    TranslationBlockSticker(
                        block: block,
                        index: index,
                        placement: OverlayGeometry.place(block.quad, in: displayRect),
                        palette: palettes[block.id] ?? .fallback,
                        onTap: { onSelect(block) }
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
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

    var body: some View {
        Button(action: onTap) {
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
        }
        .buttonStyle(.plain)
        .rotationEffect(placement.angle)
        .position(placement.center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.source)
        .accessibilityValue(block.displayText)
        .accessibilityHint(String(localized: "轻点查看原文与译文对照"))
        .accessibilityIdentifier("camera.block.\(index)")
    }
}
