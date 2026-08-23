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

/// DB（Differentiable Binarization）检测头的后处理：概率图 → 文字行的旋转矩形。
///
/// 全是纯函数，不碰 Core ML 也不碰 UIKit，因此可以脱离模型单测。
///
/// **超参数一律跟 PP-OCRv6 模型自带的 `inference.yml` 走，不要跟 PaddleOCR
/// 命令行的默认值走。** 这两套值不一样，而且命令行那套是 v4 时代的口径：
/// 曾经抄的就是它（0.3 / 0.6 / 1.5 / 512），三个阈值全都比模型自带的更严、
/// 候选上限只有六分之一，系统性地少出框。
///
/// **坐标系**：本文件全程用「概率图像素坐标」——原点左上、y 向下、单位是像素。
/// 换算到 `TextQuad` 的 Vision 归一化坐标（原点左下、y 向上）只在
/// `quads(from:mapWidth:mapHeight:)` 一处发生，别在中途翻转。
enum TextDetectionPostProcess {
    /// 概率图二值化阈值（`inference.yml` 的 thresh）。
    static let binarizationThreshold: Float = 0.2
    /// 框内平均概率低于此值就丢弃（`inference.yml` 的 box_thresh）。
    /// 纹理和反光会形成低置信度的连通块，靠它筛掉。
    static let boxScoreThreshold: Float = 0.45
    /// 外扩比例（`inference.yml` 的 unclip_ratio）。DB 训练时标注框是被收缩过的，
    /// 推理时必须扩回去，否则每行文字的首尾字母会被切掉。
    static let unclipRatio: CGFloat = 1.4
    /// 短边小于这么多像素的框直接丢——这个尺度上不可能是一行字。
    static let minimumSideLength: CGFloat = 3
    /// 单张图最多保留的候选框数，防止病态输入（如整幅噪点）把后续识别拖垮。
    ///
    /// 数值取自 `inference.yml` 的 max_candidates，但**语义与官方不同**：官方限的是
    /// 「检查多少个轮廓」，这里限的是「保留多少个框」。后者是更直接的保护，
    /// 而在 3000 这个量级上，真实照片两种口径都碰不到。
    static let maximumBoxes = 3000

    /// 一个旋转矩形，四角按左上/右上/右下/左下排列（像素坐标，y 向下）。
    struct RotatedBox: Equatable {
        /// **外扩后**的四角，用于裁剪送识别——DB 的标注框训练时被收缩过，
        /// 不扩回去会切掉每行首尾的字母。
        var corners: [CGPoint]
        /// **外扩前**的四角。行高、行距、倾角这些用于判断"是否同一段"的量必须取自它：
        /// 外扩距离是 `w·h·ratio / (2(w+h))`，跟长宽比有关（长行约 0.7h、短行更少），
        /// 拿外扩框做判据等于让阈值随每行的形状漂移。
        var tightCorners: [CGPoint]
        var score: Float

        init(corners: [CGPoint], tightCorners: [CGPoint]? = nil, score: Float) {
            self.corners = corners
            self.tightCorners = tightCorners ?? corners
            self.score = score
        }

        var minimumSide: CGFloat {
            let a = hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
            let b = hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
            return min(a, b)
        }
    }

    /// 主入口：概率图 → 旋转框。
    ///
    /// - Parameters:
    ///   - probabilities: 行优先的 `width * height` 概率值，取值 0...1。
    ///   - width/height: 概率图尺寸。
    ///   - validWidth/validHeight: 有效区域。检测输入是 letterbox 补成正方形的，
    ///     补出来的黑边不能参与连通域分析，否则黑边与图像边缘会连成一个巨框。
    static func boxes(
        probabilities: [Float],
        width: Int,
        height: Int,
        validWidth: Int,
        validHeight: Int
    ) -> [RotatedBox] {
        guard width > 0, height > 0, probabilities.count >= width * height else { return [] }
        let w = min(validWidth, width), h = min(validHeight, height)
        guard w > 0, h > 0 else { return [] }

        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let src = y * width, dst = y * w
            for x in 0..<w where probabilities[src + x] > binarizationThreshold {
                mask[dst + x] = true
            }
        }

        var result: [RotatedBox] = []
        for component in connectedComponents(mask: mask, width: w, height: h) {
            guard component.count >= 4 else { continue }
            guard var box = minimumAreaRectangle(of: component) else { continue }
            guard box.minimumSide >= minimumSideLength else { continue }

            let score = meanProbability(
                inside: box.corners, probabilities: probabilities,
                width: width, validWidth: w, validHeight: h
            )
            guard score >= boxScoreThreshold else { continue }

            let tight = box.corners
            box = RotatedBox(corners: expand(tight), tightCorners: tight, score: score)
            guard box.minimumSide >= minimumSideLength else { continue }
            result.append(clamp(box, width: w, height: h))
            if result.count >= maximumBoxes { break }
        }
        return result
    }

    // MARK: - 连通域

    /// 8 邻接连通域标记，每个连通块返回**逐行的最左/最右像素**。
    ///
    /// 只留每行两端而不是全部像素：后续唯一的用途是求凸包，而凸包完全由
    /// 每行的极值点决定（同一行的中间点必落在两端点连线上，进不了凸包）。
    /// 这样点数从 O(面积) 降到 O(高度)——一个占满画面的连通块由上万点降到千点内，
    /// Debug 构建下的差别是几十秒和几十毫秒。
    ///
    /// 用显式栈而非递归：连通块可能有上万像素，递归会爆栈。
    static func connectedComponents(mask: [Bool], width: Int, height: Int) -> [[CGPoint]] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [[CGPoint]] = []
        var stack: [Int] = []
        // 复用同一对行缓冲，避免每个连通块都重新分配 height 长的数组。
        var rowMin = [Int](repeating: Int.max, count: height)
        var rowMax = [Int](repeating: Int.min, count: height)
        var touchedRows: [Int] = []

        for start in 0..<(width * height) where mask[start] && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            touchedRows.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true

            while let index = stack.popLast() {
                let x = index % width, y = index / width
                if rowMin[y] == Int.max { touchedRows.append(y) }
                rowMin[y] = min(rowMin[y], x)
                rowMax[y] = max(rowMax[y], x)

                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let n = ny * width + nx
                        if mask[n] && !visited[n] {
                            visited[n] = true
                            stack.append(n)
                        }
                    }
                }
            }

            var outline: [CGPoint] = []
            outline.reserveCapacity(touchedRows.count * 2)
            for y in touchedRows {
                outline.append(CGPoint(x: CGFloat(rowMin[y]), y: CGFloat(y)))
                if rowMax[y] != rowMin[y] {
                    outline.append(CGPoint(x: CGFloat(rowMax[y]), y: CGFloat(y)))
                }
                rowMin[y] = Int.max
                rowMax[y] = Int.min
            }
            components.append(outline)
        }
        return components
    }

    // MARK: - 最小外接矩形

    /// Andrew 单调链凸包。返回逆时针顺序的顶点（像素坐标系 y 向下，
    /// 所以视觉上是顺时针；只要全程一致就不影响最小外接矩形）。
    static func convexHull(of points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func build(_ input: [CGPoint]) -> [CGPoint] {
            var chain: [CGPoint] = []
            for p in input {
                while chain.count >= 2, cross(chain[chain.count - 2], chain[chain.count - 1], p) <= 0 {
                    chain.removeLast()
                }
                chain.append(p)
            }
            chain.removeLast()
            return chain
        }
        let hull = build(sorted) + build(sorted.reversed())
        return hull.isEmpty ? points : hull
    }

    /// 旋转卡壳求最小面积外接矩形。
    ///
    /// 依据：最小面积外接矩形必有一条边与凸包的某条边共线。所以只需把凸包
    /// 按每条边的方向旋转到轴对齐，取面积最小的那次。
    static func minimumAreaRectangle(of points: [CGPoint]) -> RotatedBox? {
        let hull = convexHull(of: points)
        guard hull.count >= 3 else { return nil }

        var best: (area: CGFloat, corners: [CGPoint])?
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let edge = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let length = hypot(edge.x, edge.y)
            guard length > 0 else { continue }
            let ux = edge.x / length, uy = edge.y / length   // 边方向单位向量
            // 把凸包投影到（边方向, 边法向）这组基上，取轴对齐包围盒。
            var minU = CGFloat.greatestFiniteMagnitude, maxU = -CGFloat.greatestFiniteMagnitude
            var minV = CGFloat.greatestFiniteMagnitude, maxV = -CGFloat.greatestFiniteMagnitude
            for p in hull {
                let u = p.x * ux + p.y * uy
                let v = -p.x * uy + p.y * ux
                minU = min(minU, u); maxU = max(maxU, u)
                minV = min(minV, v); maxV = max(maxV, v)
            }
            let area = (maxU - minU) * (maxV - minV)
            guard area > 0, best == nil || area < best!.area else { continue }
            // 再从这组基变换回像素坐标。
            func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                CGPoint(x: u * ux - v * uy, y: u * uy + v * ux)
            }
            best = (area, [point(minU, minV), point(maxU, minV),
                           point(maxU, maxV), point(minU, maxV)])
        }
        guard let best else { return nil }
        return RotatedBox(corners: orderCorners(best.corners), score: 0)
    }

    /// 排成左上/右上/右下/左下。像素坐标系 y 向下，所以"上"= y 小。
    static func orderCorners(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return corners }
        let byY = corners.sorted { $0.y < $1.y }
        let top = byY[0...1].sorted { $0.x < $1.x }
        let bottom = byY[2...3].sorted { $0.x < $1.x }
        return [top[0], top[1], bottom[1], bottom[0]]
    }

    // MARK: - 外扩

    /// 按 DB 的 unclip 规则外扩：偏移量 d = 面积 × ratio / 周长。
    ///
    /// 官方用 pyclipper 做通用多边形 Vatti 外扩，但这里的输入恒为**矩形**，
    /// 矩形沿四边各外移 d 的结果仍是矩形，可以解析求出，不需要通用算法。
    /// 做法：把四角相对中心沿两条边方向各推 d。
    static func expand(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return corners }
        let width = hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
        let height = hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
        guard width > 0, height > 0 else { return corners }

        let area = width * height
        let perimeter = 2 * (width + height)
        let distance = area * unclipRatio / perimeter

        let ux = (corners[1].x - corners[0].x) / width      // 沿宽方向单位向量
        let uy = (corners[1].y - corners[0].y) / width
        let vx = (corners[3].x - corners[0].x) / height     // 沿高方向单位向量
        let vy = (corners[3].y - corners[0].y) / height

        // 四角各自沿"远离中心"的那对方向推 distance。
        let signs: [(CGFloat, CGFloat)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        return zip(corners, signs).map { corner, sign in
            CGPoint(
                x: corner.x + sign.0 * distance * ux + sign.1 * distance * vx,
                y: corner.y + sign.0 * distance * uy + sign.1 * distance * vy
            )
        }
    }

    private static func clamp(_ box: RotatedBox, width: Int, height: Int) -> RotatedBox {
        func clampCorners(_ corners: [CGPoint]) -> [CGPoint] {
            corners.map {
                CGPoint(x: min(max($0.x, 0), CGFloat(width - 1)),
                        y: min(max($0.y, 0), CGFloat(height - 1)))
            }
        }
        return RotatedBox(
            corners: clampCorners(box.corners),
            tightCorners: clampCorners(box.tightCorners),
            score: box.score
        )
    }

    // MARK: - 打分

    /// 框内平均概率，对齐官方 `box_score_fast`：在轴对齐包围盒里逐像素走，
    /// 但**只统计落在四边形内部的**。
    ///
    /// 别退回"整个包围盒取平均"。文字水平时两者确实等价，可一旦框有倾角，
    /// 包围盒的四个角会混进大片背景，均值被拉低——倾斜的行因此系统性掉分，
    /// 再撞上 box_thresh 就整框丢掉。这正是官方要填掩膜的原因。
    static func meanProbability(
        inside corners: [CGPoint],
        probabilities: [Float],
        width: Int,
        validWidth: Int,
        validHeight: Int
    ) -> Float {
        guard corners.count == 4 else { return 0 }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return 0 }
        let x0 = max(Int(minX.rounded(.down)), 0)
        let x1 = min(Int(maxX.rounded(.up)), validWidth - 1)
        let y0 = max(Int(minY.rounded(.down)), 0)
        let y1 = min(Int(maxY.rounded(.up)), validHeight - 1)
        guard x0 <= x1, y0 <= y1 else { return 0 }

        var total: Float = 0
        var count = 0
        for y in y0...y1 {
            let row = y * width
            for x in x0...x1 where contains(CGPoint(x: x, y: y), in: corners) {
                total += probabilities[row + x]
                count += 1
            }
        }
        // 掩膜可能一个像素都没盖住（框细到夹在两排像素中心之间）。
        // 这种框本来就没有可信的分数，回 0 让 box_thresh 直接毙掉它。
        return count == 0 ? 0 : total / Float(count)
    }

    /// 点是否在凸四边形内。旋转矩形的四角是有序的，所以只要判断点在四条边的
    /// 同一侧即可，不需要通用的射线法。叉积为 0（正好压在边上）算在内，
    /// 与 `cv2.fillPoly` 把边界像素填进掩膜的行为一致。
    private static func contains(_ point: CGPoint, in corners: [CGPoint]) -> Bool {
        var sawPositive = false, sawNegative = false
        for index in 0..<corners.count {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross > 0 { sawPositive = true }
            if cross < 0 { sawNegative = true }
            if sawPositive && sawNegative { return false }
        }
        return true
    }

    // MARK: - 坐标换算

    /// 像素坐标的旋转框 → `TextQuad`（Vision 归一化坐标：原点左下、y 向上）。
    ///
    /// 这是全流程里唯一一次翻 y 轴。`TextQuad` 约定 topLeft 是**视觉上的左上**，
    /// 翻转后它的 y 反而更大，所以像素系的 topLeft/topRight 直接对应
    /// quad 的 topLeft/topRight，不需要再交换。
    static func quad(from corners: [CGPoint], mapWidth: Int, mapHeight: Int) -> TextQuad? {
        guard corners.count == 4, mapWidth > 0, mapHeight > 0 else { return nil }
        let w = CGFloat(mapWidth), h = CGFloat(mapHeight)
        func normalize(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x / w, 0), 1), y: min(max(1 - p.y / h, 0), 1))
        }
        return TextQuad(
            topLeft: normalize(corners[0]),
            topRight: normalize(corners[1]),
            bottomRight: normalize(corners[2]),
            bottomLeft: normalize(corners[3])
        )
    }
}
