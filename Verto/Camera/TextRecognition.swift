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
import Foundation
import ImageIO

/// 一块文字在图上的四角，**Vision 归一化坐标系**：原点左下、y 向上、取值 0...1。
/// 全程保持这套坐标直到 `OverlayGeometry` 一次性换算到视图空间——中途翻转会
/// 让旋转角的符号在不同调用点各错一次。
struct TextQuad: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// 轴对齐包围盒（仍是 Vision 坐标）。
    var boundingBox: CGRect {
        let xs = [topLeft.x, topRight.x, bottomRight.x, bottomLeft.x]
        let ys = [topLeft.y, topRight.y, bottomRight.y, bottomLeft.y]
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 基线倾角（弧度）。Vision 的 y 轴向上，视图的 y 轴向下，所以视图侧
    /// 用这个角度时要取负——换算集中在 `OverlayGeometry.place(_:in:)`。
    var angle: CGFloat {
        atan2(topRight.y - topLeft.y, topRight.x - topLeft.x)
    }

    /// 沿基线方向的长度（归一化）。
    var baselineLength: CGFloat {
        hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
    }

    /// 垂直于基线的高度（归一化）。行高用它而非 boundingBox.height——
    /// 斜置文字的包围盒高度里混着水平投影。
    var uprightHeight: CGFloat {
        hypot(topLeft.x - bottomLeft.x, topLeft.y - bottomLeft.y)
    }

    /// 两块的并集，四角各取最外侧。合并同段多行时用。
    func union(_ other: TextQuad) -> TextQuad {
        TextQuad(
            topLeft: CGPoint(x: min(topLeft.x, other.topLeft.x), y: max(topLeft.y, other.topLeft.y)),
            topRight: CGPoint(x: max(topRight.x, other.topRight.x), y: max(topRight.y, other.topRight.y)),
            bottomRight: CGPoint(x: max(bottomRight.x, other.bottomRight.x), y: min(bottomRight.y, other.bottomRight.y)),
            bottomLeft: CGPoint(x: min(bottomLeft.x, other.bottomLeft.x), y: min(bottomLeft.y, other.bottomLeft.y))
        )
    }

    static func upright(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> TextQuad {
        TextQuad(
            topLeft: CGPoint(x: x, y: y + height),
            topRight: CGPoint(x: x + width, y: y + height),
            bottomRight: CGPoint(x: x + width, y: y),
            bottomLeft: CGPoint(x: x, y: y)
        )
    }
}

/// 识别出的一段文字。一段 = 视觉上归属同一块的若干行（见 `TextBlockGrouping`），
/// 整段一起送翻译——逐行翻译会把一句话切碎，译文质量掉得很明显。
struct RecognizedTextBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let quad: TextQuad
    /// 合并进来的原始行数。叠加层据此决定译文允许折几行。
    let lineCount: Int
    let confidence: Float

    init(id: UUID = UUID(), text: String, quad: TextQuad, lineCount: Int = 1, confidence: Float = 1) {
        self.id = id
        self.text = text
        self.quad = quad
        self.lineCount = lineCount
        self.confidence = confidence
    }
}

enum TextRecognitionError: LocalizedError, Equatable {
    case noTextFound
    case recognitionFailed
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .noTextFound: String(localized: "画面里没有找到文字，换个角度再试")
        case .recognitionFailed: String(localized: "文字识别出错，请重试")
        case .unsupportedLanguage: String(localized: "当前设备暂不支持识别这种语言")
        }
    }
}

protocol TextRecognitionService: Sendable {
    /// 整幅图识别。`languages` 为候选识别语言，传空数组表示交给引擎自动判定。
    /// 返回按阅读顺序（自上而下、同行自左而右）排好的段落块；无文字时抛
    /// `.noTextFound`，不返回空数组——空数组会被上层当成"成功但没内容"静默吞掉。
    ///
    /// **入参必须是已经把 EXIF 方向烘进像素的正立图**（`UIImage.normalizedUp()`）。
    /// 不再多传一个 orientation：块坐标要同时喂给识别、显示和取色三处，
    /// 三处各自记得转一次方向迟早会漏一处，不如在入口统一成一种方向。
    func recognizeText(
        in image: CGImage,
        languages: [Language]
    ) async throws -> [RecognizedTextBlock]
}

extension Language {
    /// Vision OCR 用的语言标识。
    ///
    /// **不要改用 `speechLocaleIdentifier`**：那个把 `zh-Hans` 映射成 `zh-CN`，
    /// 而 Vision 的简体中文标识就是 `zh-Hans`（`zh-CN` 不在它的支持列表里，
    /// 传进去会被静默忽略，退化成按英文识别中文——不报错，只是全是乱码）。
    /// 两者其余取值恰好相同是巧合，不是可以合并的理由。
    var visionRecognitionLanguage: String {
        switch code {
        case "zh-Hans": "zh-Hans"
        case "en": "en-US"
        case "ja": "ja-JP"
        case "ko": "ko-KR"
        case "fr": "fr-FR"
        case "es": "es-ES"
        case "de": "de-DE"
        default: code
        }
    }
}

/// 行 → 段落的合并规则。纯函数，与 Vision 解耦，便于单测。
enum TextBlockGrouping {
    /// 相邻两行的垂直间隙不超过行高的这个倍数才算同段。
    /// 1.6 是"单倍行距(≈1.2)有余、空一行(≈2.4)不够"的中间值：小于它段内不断，
    /// 大于它两段不粘。
    static let maxLineGapRatio: CGFloat = 1.6
    /// 两行水平投影的重叠比例下限（按较窄那行算）。分栏菜单左右两列各自
    /// 重叠为 0，据此不会被并成一段。
    static let minHorizontalOverlapRatio: CGFloat = 0.3
    /// 两行倾角差超过这个弧度就不合并（≈8.6°），防止把弯曲表面上分属不同
    /// 走向的行硬拉到一起。
    static let maxAngleDelta: CGFloat = 0.15
    /// 两行行高之比超过它就不合并——字号差这么多的两行是不同层级（标题 vs 正文），
    /// 不是同一段的换行。
    ///
    /// 真实 Vision 实测定的：告示上「欢迎光临」（标题）与其下「营业时间 09:00-21:00」
    /// （正文）间距只有一行高，光看间距必然被并成一段，译文于是变成一长串。
    /// 同段内换行的行高比通常在 1.15 以内（差异只来自升降部），标题与正文一般 ≥1.5，
    /// 1.4 落在两者之间。
    static let maxLineHeightRatio: CGFloat = 1.4

    /// 输入为单行块（Vision 一个 observation 一行），输出为合并后的段落块。
    /// 行序按 Vision 坐标自上而下（y 降序），同高按 x 升序。
    static func group(lines: [RecognizedTextBlock]) -> [RecognizedTextBlock] {
        let sorted = lines.sorted { lhs, rhs in
            let lhsTop = lhs.quad.boundingBox.maxY
            let rhsTop = rhs.quad.boundingBox.maxY
            // 顶边差不足一行高视为同一行，改按水平位置排。
            if abs(lhsTop - rhsTop) > min(lhs.quad.uprightHeight, rhs.quad.uprightHeight) * 0.5 {
                return lhsTop > rhsTop
            }
            return lhs.quad.boundingBox.minX < rhs.quad.boundingBox.minX
        }

        var blocks: [RecognizedTextBlock] = []
        var pendingLines: [RecognizedTextBlock] = []

        func flush() {
            guard let first = pendingLines.first else { return }
            let quad = pendingLines.dropFirst().reduce(first.quad) { $0.union($1.quad) }
            let text = pendingLines.map(\.text).reduce(into: "") { joined, line in
                joined = joined.isEmpty ? line : join(joined, line)
            }
            let confidence = pendingLines.map(\.confidence).min() ?? 0
            blocks.append(RecognizedTextBlock(
                text: text,
                quad: quad,
                lineCount: pendingLines.count,
                confidence: confidence
            ))
            pendingLines = []
        }

        for line in sorted {
            if let previous = pendingLines.last, !belongsToSameBlock(previous, line) {
                flush()
            }
            pendingLines.append(line)
        }
        flush()
        return blocks
    }

    static func belongsToSameBlock(_ lhs: RecognizedTextBlock, _ rhs: RecognizedTextBlock) -> Bool {
        guard abs(lhs.quad.angle - rhs.quad.angle) <= maxAngleDelta else { return false }

        let heights = [lhs.quad.uprightHeight, rhs.quad.uprightHeight]
        guard let shorter = heights.min(), let taller = heights.max(), shorter > 0,
              taller / shorter <= maxLineHeightRatio else {
            return false
        }

        let lhsBox = lhs.quad.boundingBox
        let rhsBox = rhs.quad.boundingBox
        let overlap = min(lhsBox.maxX, rhsBox.maxX) - max(lhsBox.minX, rhsBox.minX)
        let narrower = min(lhsBox.width, rhsBox.width)
        guard narrower > 0, overlap / narrower >= minHorizontalOverlapRatio else { return false }

        let lineHeight = max(lhs.quad.uprightHeight, rhs.quad.uprightHeight)
        guard lineHeight > 0 else { return false }
        // 上一行底边到下一行顶边的空隙；重叠（负值）自然通过。
        let gap = lhsBox.minY - rhsBox.maxY
        return gap <= lineHeight * maxLineGapRatio
    }

    /// 段内换行的接法：CJK 直接接，拉丁文补空格。中文行尾补空格会在译文里
    /// 留下多余分词，英文不补则会把两个词粘成一个。
    static func join(_ lhs: String, _ rhs: String) -> String {
        let needsSpace = !(lhs.last.map(isCJK) ?? false) && !(rhs.first.map(isCJK) ?? false)
        return needsSpace ? "\(lhs) \(rhs)" : lhs + rhs
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)   // 假名
                || (0x3400...0x4DBF).contains(scalar.value)  // 扩展 A
                || (0x4E00...0x9FFF).contains(scalar.value)  // 统一表意
                || (0xAC00...0xD7AF).contains(scalar.value)  // 谚文
                || (0xFF00...0xFF60).contains(scalar.value)  // 全角标点
        }
    }
}
