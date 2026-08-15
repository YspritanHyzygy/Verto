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

/// 送进检测模型的方形画布。
///
/// 原图等比缩放到长边 = `side`，贴在左上角，其余补黑（letterbox）。
/// 补边是必要的：检测模型输入形状固定 960×960，而固定形状是神经引擎的前提，
/// 动态形状会让 Core ML 退回 CPU/GPU。
///
/// **坐标系**：`pixels` 用画布像素坐标——原点左上、y 向下，与
/// `TextDetectionPostProcess` 一致。
struct OCRImageCanvas {
    let side: Int
    /// 有效区域（原图缩放后的尺寸），补边不算在内。
    let scaledWidth: Int
    let scaledHeight: Int
    /// RGBA8，行优先，长度 `side * side * 4`。
    private let pixels: [UInt8]

    init?(image: CGImage, side: Int) {
        guard side > 0, image.width > 0, image.height > 0 else { return nil }
        self.side = side

        let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
        scaledWidth = max(1, min(side, Int((Double(image.width) * scale).rounded())))
        scaledHeight = max(1, min(side, Int((Double(image.height) * scale).rounded())))

        // 闭包里只能碰局部量：此刻 `pixels` 还没初始化，引用任何存储属性都会
        // 被判成"初始化前捕获 self"。
        let bytesPerRow = side * 4
        let drawWidth = CGFloat(scaledWidth), drawHeight = CGFloat(scaledHeight)
        let canvasSide = side
        var buffer = [UInt8](repeating: 0, count: side * bytesPerRow)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: canvasSide, height: canvasSide,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            // **不要在这里翻 y。** 位图内存的第 0 行本来就对应图像顶部，
            // 而 CGContext 的坐标原点在左下——两者已经互相抵消，直接画就是正的。
            // 额外加一次 `scaleBy(y: -1)` 会把图像内容上下颠倒（位置看着还对，
            // 因为后面 quad 换算又翻了一次，两次抵消），结果是检测框位置正常、
            // 送进识别模型的却是倒着的图，识别出一串似是而非的字。这里踩过。
            //
            // 要让缩放图落在画布**左上角**（补边在右下），只需把它画在 CG 坐标的
            // 上边缘，即 y = side - 高度。
            context.draw(image, in: CGRect(x: 0, y: CGFloat(canvasSide) - drawHeight,
                                           width: drawWidth, height: drawHeight))
            return true
        }
        guard ok else { return nil }
        pixels = buffer
    }

    /// 直接把整张画布写成检测模型要的 CHW float32 张量（含补边区）。
    ///
    /// 写成一次性填充而不是"逐像素回调"：这里有 92 万个像素，Debug 构建不做
    /// 内联，每像素一次闭包调用会把一次识别拖到几十秒——测试正是跑在 Debug 下的。
    func fillDetectorInput(into destination: UnsafeMutablePointer<Float>) {
        let mean = OCRModelPack.detectorMean, std = OCRModelPack.detectorStd
        let plane = side * side
        pixels.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for index in 0..<plane {
                let p = index * 4
                destination[index] = (Float(base[p]) / 255 - mean.0) / std.0
                destination[plane + index] = (Float(base[p + 1]) / 255 - mean.1) / std.1
                destination[2 * plane + index] = (Float(base[p + 2]) / 255 - mean.2) / std.2
            }
        }
    }

    /// 按旋转框裁出一行文字，摆正并缩放到识别模型的固定输入尺寸。
    ///
    /// 用直接双线性采样而不是 CGContext 变换：这里同时涉及旋转、缩放和
    /// y 轴方向，用仿射矩阵叠出来极易在某一处符号弄反，而采样式写法把
    /// "目标像素来自源图哪一点"写成一行，对错一眼可见。
    func crop(_ corners: [CGPoint]) -> OCRLineCrop? {
        guard corners.count == 4 else { return nil }
        let topLeft = corners[0], topRight = corners[1], bottomLeft = corners[3]
        let boxWidth = hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
        let boxHeight = hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y)
        guard boxWidth > 1, boxHeight > 1 else { return nil }

        let outHeight = OCRModelPack.recognizerInputHeight
        let maxWidth = OCRModelPack.recognizerInputWidth
        // 等比映射到 48 高；比 640 还宽的行按比例压进来（宁可压扁也别切断，
        // 切断会整段丢字，压扁只是稍微降低置信度）。
        let used = max(16, min(maxWidth, Int((Double(outHeight) * boxWidth / boxHeight).rounded())))

        var out = [UInt8](repeating: 0, count: outHeight * maxWidth * 3)
        let edgeU = CGPoint(x: topRight.x - topLeft.x, y: topRight.y - topLeft.y)
        let edgeV = CGPoint(x: bottomLeft.x - topLeft.x, y: bottomLeft.y - topLeft.y)

        pixels.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for y in 0..<outHeight {
                let v = (Double(y) + 0.5) / Double(outHeight)
                for x in 0..<used {
                    let u = (Double(x) + 0.5) / Double(used)
                    let sx = Double(topLeft.x) + u * Double(edgeU.x) + v * Double(edgeV.x)
                    let sy = Double(topLeft.y) + u * Double(edgeU.y) + v * Double(edgeV.y)
                    let (r, g, b) = sample(base, x: sx, y: sy)
                    let p = (y * maxWidth + x) * 3
                    out[p] = r; out[p + 1] = g; out[p + 2] = b
                }
            }
        }
        return OCRLineCrop(width: maxWidth, height: outHeight, usedWidth: used, pixels: out)
    }

    /// 双线性采样，越界按边缘钳制。
    private func sample(_ base: UnsafePointer<UInt8>, x: Double, y: Double) -> (UInt8, UInt8, UInt8) {
        let cx = min(max(x, 0), Double(side - 1))
        let cy = min(max(y, 0), Double(side - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, side - 1), y1 = min(y0 + 1, side - 1)
        let fx = cx - Double(x0), fy = cy - Double(y0)

        func channel(_ offset: Int) -> UInt8 {
            let p00 = Double(base[(y0 * side + x0) * 4 + offset])
            let p10 = Double(base[(y0 * side + x1) * 4 + offset])
            let p01 = Double(base[(y1 * side + x0) * 4 + offset])
            let p11 = Double(base[(y1 * side + x1) * 4 + offset])
            let top = p00 + (p10 - p00) * fx
            let bottom = p01 + (p11 - p01) * fx
            return UInt8(min(max((top + (bottom - top) * fy).rounded(), 0), 255))
        }
        return (channel(0), channel(1), channel(2))
    }
}

/// 摆正后的一行文字，尺寸恒为识别模型的固定输入。`usedWidth` 右侧是补白。
struct OCRLineCrop {
    let width: Int
    let height: Int
    /// 实际有内容的宽度，右侧到 `width` 之间是补白。解码时据此裁掉尾部时间步。
    let usedWidth: Int
    /// RGB8，行优先，长度 `height * width * 3`。
    private let pixels: [UInt8]

    init(width: Int, height: Int, usedWidth: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.usedWidth = usedWidth
        self.pixels = pixels
    }

    /// 写成识别模型要的 CHW float32 张量。只写有内容的区域，
    /// 补白区由调用方预先置零——归一化后 0 正是训练时 padding 的取值。
    func fillRecognizerInput(into destination: UnsafeMutablePointer<Float>) {
        let mean = OCRModelPack.recognizerMean, std = OCRModelPack.recognizerStd
        let plane = height * width
        pixels.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for y in 0..<height {
                let rowStart = y * width
                for x in 0..<usedWidth {
                    let index = rowStart + x
                    let p = index * 3
                    destination[index] = (Float(base[p]) / 255 - mean) / std
                    destination[plane + index] = (Float(base[p + 1]) / 255 - mean) / std
                    destination[2 * plane + index] = (Float(base[p + 2]) / 255 - mean) / std
                }
            }
        }
    }
}
