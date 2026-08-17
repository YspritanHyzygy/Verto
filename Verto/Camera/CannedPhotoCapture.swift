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

import AVFoundation
import CoreGraphics
import ImageIO
import UIKit

#if DEBUG
/// UI 测试用的合成告示牌：`--uitest-canned-camera` 注入，零真实相机/权限/Vision。
///
/// 画出来的图和"识别"出来的文字块**共用同一份行数据**——这样叠加层落在真正
/// 画着字的位置上，截图验收才有意义。文案与坐标只此一份，不许在别处再抄。
enum CannedSignFixture {
    struct Line {
        let text: String
        /// Vision 归一化矩形：原点左下、y 向上。
        let rect: CGRect
    }

    /// 竖排告示牌比例，够大以免 Vision 式的小字号在缩放后糊掉。
    static let pixelSize = CGSize(width: 900, height: 1200)
    static let background = UIColor(red: 0.93, green: 0.90, blue: 0.83, alpha: 1)
    static let ink = UIColor(red: 0.13, green: 0.12, blue: 0.10, alpha: 1)

    static let lines: [Line] = [
        Line(text: "欢迎光临", rect: CGRect(x: 0.14, y: 0.70, width: 0.52, height: 0.075)),
        Line(text: "营业时间 09:00-21:00", rect: CGRect(x: 0.14, y: 0.60, width: 0.72, height: 0.045)),
        Line(text: "禁止吸烟", rect: CGRect(x: 0.14, y: 0.30, width: 0.40, height: 0.055))
    ]

    static func renderImage() -> UIImage {
        let size = pixelSize
        return UIGraphicsImageRenderer(size: size).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            for line in lines {
                // Vision 原点在左下，CoreGraphics 绘制原点在左上：翻 y。
                let frame = CGRect(
                    x: line.rect.minX * size.width,
                    y: (1 - line.rect.maxY) * size.height,
                    width: line.rect.width * size.width,
                    height: line.rect.height * size.height
                )
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: frame.height * 0.82, weight: .semibold),
                    .foregroundColor: ink
                ]
                (line.text as NSString).draw(in: frame, withAttributes: attributes)
            }
        }
    }
}

/// 合成拍照：立即返回固定图片，不做任何人为延迟——需要观察"识别中"状态的是
/// 真实管线，罐头路径刻意让终态尽快稳定，好让 UI 断言有确定落点。
@Observable
@MainActor
final class CannedPhotoCaptureSource: PhotoCaptureSource {
    let canCapture = true
    let isFlashAvailable = true
    let isPermissionDenied = false
    /// 无真实取景层；相机页据此显示中性背景，快门照常可用。
    let previewLayer: AVCaptureVideoPreviewLayer? = nil
    let isAdjustingFocus = false
    let isAdjustingExposure = false
    private(set) var focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
    private(set) var displayZoomFactor: CGFloat = 1
    let minimumDisplayZoomFactor: CGFloat = 1
    let maximumDisplayZoomFactor: CGFloat = 5

    func start() async {}
    func stop() {}
    func setFlashEnabled(_ enabled: Bool) {}
    func focusAndMeter(at devicePoint: CGPoint) { focusPointOfInterest = devicePoint }
    func setDisplayZoomFactor(_ factor: CGFloat) {
        displayZoomFactor = min(max(factor, minimumDisplayZoomFactor), maximumDisplayZoomFactor)
    }
    /// 无取景层可冻。
    func setPreviewFrozen(_ frozen: Bool) {}

    func capturePhoto() async throws -> UIImage {
        CannedSignFixture.renderImage()
    }
}

/// 合成识别：无论输入什么图都回同一组文字块，块的位置与
/// `CannedSignFixture` 画出来的字一一对齐。
///
/// 只吐原始块，不做任何"识别得对不对"的自我判定——那是测试端的事
/// （AGENTS.md 第四条）。
struct CannedTextRecognitionService: TextRecognitionService {
    func recognizeText(
        in image: CGImage,
        languages: [Language]
    ) async throws -> [RecognizedTextBlock] {
        CannedSignFixture.lines.map { line in
            RecognizedTextBlock(
                text: line.text,
                quad: .upright(
                    x: line.rect.minX,
                    y: line.rect.minY,
                    width: line.rect.width,
                    height: line.rect.height
                )
            )
        }
    }
}
#endif
