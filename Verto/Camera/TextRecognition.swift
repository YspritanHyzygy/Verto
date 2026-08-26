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
import NaturalLanguage

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

    /// 把在"转正后的图"里量到的框搬回原图坐标。`OCRImageStraightening.straighten`
    /// 的逆运算，两者必须同进同退——所以写在一起。
    ///
    /// 归一化坐标各轴独立除以自己的边长，转 90° 带来的长宽互换已经被归一化吸收，
    /// 于是这里只是在单位正方形里转点：顺时针一格就是 `(x, y) → (y, 1 - x)`。
    /// （Vision 的 y 向上，y=1 是画面视觉上的顶边，所以"顺时针"和肉眼看到的一致。）
    ///
    /// **四角的名字不跟着转。** `topLeft` 说的是"这行文字的左上角"，不是"图的左上角"；
    /// 转回去之后它还是同一个物理角。跟着重命名会让 `angle` 丢掉这行真实的倾角，
    /// 贴纸也就不会跟着躺下来。
    func rotatedClockwise(quarterTurns: Int) -> TextQuad {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return self }
        func spin(_ point: CGPoint) -> CGPoint {
            var point = point
            for _ in 0..<turns {
                point = CGPoint(x: point.y, y: 1 - point.x)
            }
            return point
        }
        return TextQuad(
            topLeft: spin(topLeft),
            topRight: spin(topRight),
            bottomRight: spin(bottomRight),
            bottomLeft: spin(bottomLeft)
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

    /// 沿文字基线切出一段四边形。CTC 时间步只能给近似水平位置，生成的框只服务
    /// 点击与选择；擦除掩码仍由原图像素决定。
    func horizontalSlice(from lower: CGFloat, to upper: CGFloat) -> TextQuad {
        let lower = min(max(lower, 0), 1)
        let upper = min(max(upper, lower), 1)
        func point(_ start: CGPoint, _ end: CGPoint, _ amount: CGFloat) -> CGPoint {
            CGPoint(
                x: start.x + (end.x - start.x) * amount,
                y: start.y + (end.y - start.y) * amount
            )
        }
        return TextQuad(
            topLeft: point(topLeft, topRight, lower),
            topRight: point(topLeft, topRight, upper),
            bottomRight: point(bottomLeft, bottomRight, upper),
            bottomLeft: point(bottomLeft, bottomRight, lower)
        )
    }
}

/// 送去识别之前把画面转正。**只作用于识别用的那份副本**，照片本身一个像素不改
/// （见 `CapturedPhoto`）。
///
/// 非转不可的原因：检测与后处理全都假设文字是横排的。歪着送进去，
/// `TextDetectionPostProcess.orderCorners` 会把竖行的短边当成上边，
/// `OCRImageCanvas.crop` 随即把一条 20×200 的竖行重采样成 16×48 的糊块——
/// 就是横屏结果里"每块只剩一两个字符"的成因。Vision 那条路同样吃亏。
enum OCRImageStraightening {
    /// `quarterTurnsClockwise` 是画面里的世界相对正立被顺时针转过的 90° 数，
    /// 所以转正就是往回**逆时针**转同样多。0 时原样返回，不白拷一张。
    ///
    /// 建不出位图上下文时原样返回：识别质量会掉回没转之前，但不会把这张照片作废。
    static func straighten(_ image: CGImage, quarterTurnsClockwise turns: Int) -> CGImage {
        let turns = ((turns % 4) + 4) % 4
        guard turns != 0 else { return image }

        let width = image.width
        let height = image.height
        let swapsAxes = turns % 2 == 1
        let destinationWidth = swapsAxes ? height : width
        let destinationHeight = swapsAxes ? width : height

        // 固定用 DeviceRGB + 32bpp：这份副本只喂识别器，不参与取色，
        // 色彩空间保真没有意义，而"什么图都建得出上下文"有。
        guard let context = CGContext(
            data: nil,
            width: destinationWidth,
            height: destinationHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return image
        }

        // CGContext 原点在左下、y 向上，`rotate(by:)` 正角为逆时针。
        // 先把转完之后落到画外的那半平移回来，再画整张原图。
        switch turns {
        case 1:
            context.translateBy(x: CGFloat(height), y: 0)
            context.rotate(by: .pi / 2)
        case 2:
            context.translateBy(x: CGFloat(width), y: CGFloat(height))
            context.rotate(by: .pi)
        default:
            context.translateBy(x: 0, y: CGFloat(width))
            context.rotate(by: -.pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

struct RecognizedTextToken: Equatable, Sendable {
    let text: String
    let quad: TextQuad
    let confidence: Float

    func rotatedClockwise(quarterTurns: Int) -> RecognizedTextToken {
        RecognizedTextToken(
            text: text,
            quad: quad.rotatedClockwise(quarterTurns: quarterTurns),
            confidence: confidence
        )
    }
}

struct RecognizedTextLine: Equatable, Sendable {
    let text: String
    let quad: TextQuad
    let metricsQuad: TextQuad
    let confidence: Float
    let tokens: [RecognizedTextToken]

    init(
        text: String,
        quad: TextQuad,
        metricsQuad: TextQuad? = nil,
        confidence: Float = 1,
        tokens: [RecognizedTextToken] = []
    ) {
        self.text = text
        self.quad = quad
        self.metricsQuad = metricsQuad ?? quad
        self.confidence = confidence
        self.tokens = tokens.isEmpty && !text.isEmpty
            ? [RecognizedTextToken(text: text, quad: quad, confidence: confidence)]
            : tokens
    }

    func rotatedClockwise(quarterTurns: Int) -> RecognizedTextLine {
        RecognizedTextLine(
            text: text,
            quad: quad.rotatedClockwise(quarterTurns: quarterTurns),
            metricsQuad: metricsQuad.rotatedClockwise(quarterTurns: quarterTurns),
            confidence: confidence,
            tokens: tokens.map { $0.rotatedClockwise(quarterTurns: quarterTurns) }
        )
    }
}

/// 识别出的一段文字。一段保留完整逐行和逐词几何，整段文字仍一起送翻译。
struct RecognizedTextBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    let lines: [RecognizedTextLine]

    var text: String {
        lines.map(\.text).reduce(into: "") { joined, line in
            joined = joined.isEmpty ? line : TextBlockGrouping.join(joined, line)
        }
    }

    var quad: TextQuad { Self.union(lines.map(\.quad)) }
    var metricsQuad: TextQuad { Self.union(lines.map(\.metricsQuad)) }
    var lineCount: Int { lines.count }
    var confidence: Float { lines.map(\.confidence).min() ?? 0 }

    init(id: UUID = UUID(), lines: [RecognizedTextLine]) {
        precondition(!lines.isEmpty)
        self.id = id
        self.lines = lines
    }

    init(
        id: UUID = UUID(),
        text: String,
        quad: TextQuad,
        metricsQuad: TextQuad? = nil,
        confidence: Float = 1,
        tokens: [RecognizedTextToken] = []
    ) {
        self.init(
            id: id,
            lines: [
                RecognizedTextLine(
                    text: text,
                    quad: quad,
                    metricsQuad: metricsQuad,
                    confidence: confidence,
                    tokens: tokens
                )
            ]
        )
    }

    private static func union(_ quads: [TextQuad]) -> TextQuad {
        quads.dropFirst().reduce(quads[0]) { $0.union($1) }
    }
}

/// 统一 Vision 与 CTC 的分词规则。拉丁文字保留词尾标点，CJK 先用系统词法分段；
/// 分词器没有结果时退回逐字范围。
enum TextTokenization {
    struct TokenRange {
        let text: String
        let stringRange: Range<String.Index>
        let characterRange: Range<Int>
    }

    static func ranges(in text: String) -> [TokenRange] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var wordRanges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            wordRanges.append(range)
            return true
        }

        let ranges = wordRanges.isEmpty ? characterRanges(in: text) : wordRanges.map { word in
            var lower = word.lowerBound
            var upper = word.upperBound
            while lower > text.startIndex {
                let previous = text.index(before: lower)
                guard isJoinablePunctuation(text[previous]) else { break }
                lower = previous
            }
            while upper < text.endIndex, isJoinablePunctuation(text[upper]) {
                upper = text.index(after: upper)
            }
            return lower..<upper
        }

        var seen: Set<String.Index> = []
        return ranges.compactMap { range in
            guard !seen.contains(range.lowerBound) else { return nil }
            seen.insert(range.lowerBound)
            let token = String(text[range])
            guard token.contains(where: { !$0.isWhitespace }) else { return nil }
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: range.upperBound)
            return TokenRange(text: token, stringRange: range, characterRange: lower..<upper)
        }
    }

    private static func characterRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if !text[index].isWhitespace { ranges.append(index..<next) }
            index = next
        }
        return ranges
    }

    private static func isJoinablePunctuation(_ character: Character) -> Bool {
        !character.isWhitespace && character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
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
        case .unsupportedLanguage: String(localized: "此设备无法识别这种语言，请选择其他语言")
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
    /// 单块行数的病态上限。这不是版面设计上的限制——真实段落到不了这个数——
    /// 而是万一前面所有判据都被绕过时，别让一块吞掉整页的兜底。
    static let maxLinesPerBlock = 60

    /// 阅读顺序：自上而下，同一行带内自左而右。
    ///
    /// 分两步做，而不是写成一个带容差的比较器。带容差的比较器会产生
    /// A≈B、B≈C 却 A≉C 的非传递关系，那不是严格弱序——`sorted` 在这种比较器下
    /// 结果**未定义**，同一张图两次识别可能得到不同的行序，顺序合并随后就在
    /// 一个非阅读序的序列上走。这正是"竖屏有时候正常有时候不对"的来源。
    ///
    /// 第一步按顶边排全序（无容差，严格弱序成立）；第二步单趟扫描切分行带，
    /// 容差在扫描里用而不在比较里用，于是既保留了"同一行按水平位置排"，
    /// 又不留下未定义行为。
    static func readingOrder(_ lines: [RecognizedTextBlock]) -> [RecognizedTextBlock] {
        let byTop = lines.sorted { lhs, rhs in
            let lhsTop = lhs.metricsQuad.boundingBox.maxY
            let rhsTop = rhs.metricsQuad.boundingBox.maxY
            if lhsTop != rhsTop { return lhsTop > rhsTop }
            return lhs.metricsQuad.boundingBox.minX < rhs.metricsQuad.boundingBox.minX
        }

        var rows: [[RecognizedTextBlock]] = []
        for line in byTop {
            // 与本行带的**锚行**比，不与上一行比：逐行放宽会让行带顺着一串
            // 各自合格的小台阶一路滑下去。
            if let anchor = rows.last?.first,
               anchor.metricsQuad.boundingBox.maxY - line.metricsQuad.boundingBox.maxY
                <= min(anchor.metricsQuad.uprightHeight, line.metricsQuad.uprightHeight) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        return rows.flatMap { row in
            row.sorted { $0.metricsQuad.boundingBox.minX < $1.metricsQuad.boundingBox.minX }
        }
    }

    /// 一行有没有"内容"——至少要有一个字母、数字或表意文字。
    ///
    /// OCR 会把反光、划痕、logo 边缘认成一两个标点（真机实测出过 `:` 和 `)`）。
    /// 这种块照样会被贴一张有底色的贴片上去，在照片上就是一坨没有字的怪东西——
    /// 用户截图里那个云朵状色块就是两个这样的块叠在一起。
    /// 纯标点的"行"不可能是需要翻译的文字，在进合并之前就丢掉。
    static func carriesContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (0x3040...0x30FF).contains(scalar.value)   // 假名
                || (0x3400...0x4DBF).contains(scalar.value)   // 扩展 A
                || (0x4E00...0x9FFF).contains(scalar.value)   // 统一表意
                || (0xAC00...0xD7AF).contains(scalar.value)   // 谚文
        }
    }

    /// 输入为单行块（Vision 一个 observation 一行），输出为合并后的段落块。
    /// 行序按 Vision 坐标自上而下（y 降序），同高按 x 升序。
    static func group(lines: [RecognizedTextBlock]) -> [RecognizedTextBlock] {
        let sorted = readingOrder(lines.filter { carriesContent($0.text) })

        var blocks: [RecognizedTextBlock] = []
        var pendingLines: [RecognizedTextBlock] = []
        // 累积并集随扫描增量维护；每行重算一遍是 O(n²)。
        // 两个框各并各的：显示框并出去给叠加层，判据框并了留给下一轮合并用。
        func flush() {
            guard !pendingLines.isEmpty else { return }
            blocks.append(RecognizedTextBlock(lines: pendingLines.flatMap(\.lines)))
            pendingLines = []
        }

        for line in sorted {
            if let previous = pendingLines.last,
               !belongsToSameBlock(previous, line) || !belongsToBlock(pendingLines, line: line) {
                flush()
            }
            pendingLines.append(line)
        }
        flush()
        return blocks
    }

    /// 逐对判据之外，新行还要与**已累积的整块**相容。
    ///
    /// 只跟上一行比，块会顺着一串"每一对都刚好合格"的行漂走：行高每行变一点、
    /// 栏位每行偏一点，十几行之后首尾已是毫不相干的两段，中间却没有任何一步不合格。
    /// 而 `union` 取四角最外侧——一次误连就把中间所有东西一起圈进同一个框，
    /// 于是一块盖住大半张照片。
    static func belongsToBlock(_ lines: [RecognizedTextBlock], line: RecognizedTextBlock) -> Bool {
        guard lines.count < maxLinesPerBlock else { return false }
        guard let anchor = lines.first else { return true }

        // 行高与块内**首行**比而非上一行：同段各行字号本就一致，
        // 以标题起头的块因此挡得住紧随其后的正文。
        let heights = [anchor.metricsQuad.uprightHeight, line.metricsQuad.uprightHeight]
        guard let shorter = heights.min(), let taller = heights.max(), shorter > 0,
              taller / shorter <= maxLineHeightRatio else {
            return false
        }

        // 水平投影同样与首行比。**不能**改成与已累积的并集比：并集只会越长越宽，
        // 逐行右移的阶梯反而更容易通过它，等于没设防。
        let anchorBox = anchor.metricsQuad.boundingBox
        let lineBox = line.metricsQuad.boundingBox
        let overlap = min(anchorBox.maxX, lineBox.maxX) - max(anchorBox.minX, lineBox.minX)
        let narrower = min(anchorBox.width, lineBox.width)
        guard narrower > 0, overlap / narrower >= minHorizontalOverlapRatio else { return false }

        return true
    }

    static func belongsToSameBlock(_ lhs: RecognizedTextBlock, _ rhs: RecognizedTextBlock) -> Bool {
        guard abs(lhs.metricsQuad.angle - rhs.metricsQuad.angle) <= maxAngleDelta else { return false }

        let heights = [lhs.metricsQuad.uprightHeight, rhs.metricsQuad.uprightHeight]
        guard let shorter = heights.min(), let taller = heights.max(), shorter > 0,
              taller / shorter <= maxLineHeightRatio else {
            return false
        }

        let lhsBox = lhs.metricsQuad.boundingBox
        let rhsBox = rhs.metricsQuad.boundingBox
        let overlap = min(lhsBox.maxX, rhsBox.maxX) - max(lhsBox.minX, rhsBox.minX)
        let narrower = min(lhsBox.width, rhsBox.width)
        guard narrower > 0, overlap / narrower >= minHorizontalOverlapRatio else { return false }

        let lineHeight = max(lhs.metricsQuad.uprightHeight, rhs.metricsQuad.uprightHeight)
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
