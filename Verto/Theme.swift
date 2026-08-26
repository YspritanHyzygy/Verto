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
import UIKit

/// 暖色"夜纸"调色板：深色不走中性灰，保持纸墨的棕色底调；
/// 深色下卡片比纸面亮一档，用明度差代替阴影表达层级。
enum AppTheme {
    static let paper = Color(light: 0xF7F4EF, dark: 0x201D1A)
    static let page = Color(light: 0xE8E4DD, dark: 0x171412)
    /// 抬升的卡片面，取代散落各处的 .white 卡底。
    static let card = Color(light: 0xFFFFFF, dark: 0x2B2723)
    /// 凹陷底：分段控件轨道、关闭按钮圆底、"即将推出"胶囊。
    static let inset = Color(light: 0xEAE5DB, dark: 0x161310)
    static let ink = Color(light: 0x1C1A17, dark: 0xECE7DF)
    static let secondaryInk = Color(light: 0x5C564D, dark: 0xC2BAAE)
    static let muted = Color(light: 0x8A8276, dark: 0x9E968B)
    static let faint = Color(light: 0xB9B0A2, dark: 0x6F675C)
    /// 深色下提亮一档，否则赤陶在暗底上对比度不足。
    static let terracotta = Color(light: 0xC2603F, dark: 0xD0714F)
    /// 白字压在其上的赤陶填充面（气泡、按钮胶囊）：保持原深赤陶不提亮，
    /// 否则白字对比度掉到 3:1 以下。图标类填充（≥3:1 即可）继续用 terracotta。
    static let terracottaFill = Color(hex: 0xC2603F)
    static let terracottaSoft = Color(light: 0xF7ECE6, dark: 0x322520)
    /// 译文正文衬线字色。
    static let resultInk = Color(light: 0x26221D, dark: 0xE4DED4)
    /// 结果卡上复制/收藏/分享图标。
    static let actionMuted = Color(light: 0xB79A8C, dark: 0xC9A288)
    /// 赤陶气泡上的语言小标签。
    static let bubbleAccentLabel = Color(light: 0xC99A85, dark: 0xD5A084)
    /// 错误/重试文字。
    static let alert = Color(light: 0xB4443C, dark: 0xE07A6C)
    /// 压在照片（而非 app 纸面）上的固定告警色：译文贴片的底色是从原图采样来的，
    /// 自适应 token 会在浅色照片上被冲淡，这里必须钉死一个高对比红。
    /// 快门盘上的内容色。快门盘是固定白色的相机件，压在它上面的转圈也必须固定深色——
    /// 用自适应的 ink 会在深色模式下变浅米色，白盘上直接隐形。
    static let shutterInk = Color(hex: 0x1C1A17)
    /// 相机页没有取景画面（模拟器无摄像头、权限被拒）时的底。
    /// **必须固定深色**：相机页整套 chrome（白字、白描边玻璃钮、半透明黑胶囊）
    /// 是按压在照片上设计的，底一旦跟着浅色模式变浅，白字和闪光灯图标就地隐形。
    static let cameraBackdrop = Color(hex: 0x2A2622)
    static let divider = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.06)
    })
}

extension AppearanceMode {
    /// nil = 跟随系统（不覆盖）。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }

    /// 明暗自适应颜色；走 UIColor trait 回调，随系统外观和 preferredColorScheme 覆盖实时解析。
    init(light: UInt, dark: UInt) {
        self.init(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

extension View {
    /// 深色下黑影几乎不可见，层级主要靠 card/paper 明度差；阴影加深仅为叠层边缘辨识。
    func softShadow(radius: CGFloat = 10, y: CGFloat = 4, opacity: Double = 0.06) -> some View {
        shadow(
            color: Color(uiColor: UIColor { trait in
                UIColor.black.withAlphaComponent(
                    trait.userInterfaceStyle == .dark ? min(opacity * 3, 0.5) : opacity
                )
            }),
            radius: radius, x: 0, y: y
        )
    }

    func cardBackground(_ color: Color = AppTheme.card, radius: CGFloat = 22) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .softShadow(radius: 8, y: 2, opacity: 0.045)
    }
}

// MARK: - Liquid Glass (iOS 26+)，iOS 17-25 回退

extension View {
    /// iOS 26+：交互式液体玻璃，裁剪到 shape，可选着色。
    /// iOS 17-25：执行 fallback 闭包，原样保留改造前的背景/阴影链。
    /// 像 background 一样，在 frame/padding 之后调用。
    /// interactive 的拖拽形变只带动玻璃和它内部的内容，静态的同心装饰
    /// （光晕、描边覆盖层）不会跟随——这类按钮要传 interactive: false。
    @ViewBuilder
    func liquidGlass<S: Shape, Fallback: View>(
        tint: Color? = nil,
        interactive: Bool = true,
        clear: Bool = false,
        in shape: S,
        @ViewBuilder fallback: (Self) -> Fallback
    ) -> some View {
        if #available(iOS 26.0, *) {
            if clear {
                // Clear 没有透明度档位；18% 真机仍像裸玻璃，24% 是在保留底图的同时
                // 加回一小层雾色。相机浮层在调用处使用浅色语义环境来托住深色前景。
                background(.white.opacity(0.24), in: shape)
                    .glassEffect(.clear.tint(tint).interactive(interactive), in: shape)
            } else {
                glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
            }
        } else {
            fallback(self)
        }
    }

    /// iOS 26+ 用 GlassEffectContainer 包裹，让邻近/重叠的玻璃形状统一采样融合；早期系统为 no-op。
    @ViewBuilder
    func liquidGlassContainer(spacing: CGFloat? = nil) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}
