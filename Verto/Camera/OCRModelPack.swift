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

import Foundation

/// 高精度识别引擎的模型档位。
///
/// 三档都是 PP-OCRv6（转成 Core ML fp16），差别只在模型大小。前后处理超参
/// 三档共用，构建源见
/// `https://github.com/YspritanHyzygy/PP-OCR-for-Apple/blob/main/scripts/build_models.py`。
/// 模型不进 app bundle，
/// 用户在设置里选档下载，也可以删掉退回系统引擎。
enum OCRModelTier: String, CaseIterable, Identifiable, Sendable {
    case tiny
    case small
    case medium

    var id: String { rawValue }

    /// 默认档。首次进相机页自动下载的就是它：12MB 的下载量能接受，
    /// 准确率 81.3 已经明显超过系统引擎，而 medium 要 44MB 只多 1.9 分。
    static let `default`: OCRModelTier = .small

    var displayName: String {
        switch self {
        case .tiny: String(localized: "轻量")
        case .small: String(localized: "均衡")
        case .medium: String(localized: "最高精度")
        }
    }

    /// PaddleOCR 官方在 16 类真实照片基准上的加权平均准确率（W-Avg）。
    /// 作对比：同一基准上 Gemini-3.1-Pro 71.4、GPT-5.5 64.2。
    var accuracy: Double {
        switch self {
        case .tiny: 73.5
        case .small: 81.3
        case .medium: 83.2
        }
    }

    /// 压缩包字节数，与 `sha256` 一样由
    /// `https://github.com/YspritanHyzygy/PP-OCR-for-Apple/blob/main/manifests/v1.json`
    /// 锁定；换模型必须把两者一起同步过来。
    var downloadBytes: Int64 {
        switch self {
        case .tiny: 2_915_454
        case .small: 12_999_796
        case .medium: 47_521_629
        }
    }

    var sha256: String {
        switch self {
        case .tiny: "c0eba9a3affa1f2a5591e07739d9ca861d9f9417bf0258e56c1b06e9299a1aba"
        case .small: "8f32f551fdddd7cb136ce54e7566aa453e1ca6f7c1f6a6ae7d1f75de1addfe10"
        case .medium: "960ed7c0065e3d21d1b52cc1a0ae3fb1b28911d5735f455cc82483009c3128be"
        }
    }

    /// Apple Archive 格式。iOS 没有公开的解 zip API，而 AppleArchive
    /// 是系统 Swift 模块，解包不需要引入任何三方库。
    var archiveName: String { "pp-ocr-v6-coreml-\(rawValue)-v\(OCRModelPack.version).aar" }

    var archiveURL: URL { OCRModelPack.releaseBaseURL.appendingPathComponent(archiveName) }

    /// 本档识别模型是否覆盖某种语言的文字。
    ///
    /// **PP-OCRv6 三档全部没有谚文**（字表里谚文音节与谚文字母都是 0 条），
    /// 所以韩语只能继续走系统引擎——模型卡上写的 "supports 50 languages"
    /// 指的是 50 种拉丁系语言加中日，不含谚文/西里尔/阿拉伯/泰文/天城文。
    /// tiny 档字表 6904 条，另外还砍掉了日文假名。
    func recognizes(_ language: Language) -> Bool {
        switch language.code {
        case "ko": false
        case "ja": self != .tiny
        default: true
        }
    }

    /// 这一档搞不定、必须回落到系统引擎的语言。设置页据此给出提示，
    /// 不让用户以为下载完就万能了。
    var unsupportedLanguages: [Language] {
        Language.all.filter { !recognizes($0) }
    }
}

/// 模型包的全局常量与磁盘布局。
enum OCRModelPack {
    /// 模型包格式版本。改前后处理超参、换模型代次都要进版本号——
    /// 版本号进目录名，旧包因此不会被新代码误读，升级时自然作废。
    static let version = "1"

    /// 模型工程与产物统一托管在专用仓库；Verto 的 Release 只留给 app 本身。
    /// 仍使用 GitHub Release 资产，是因为它走 CDN、URL 稳定且不撑大 git 仓库。
    static let releaseBaseURL = URL(
        string: "https://github.com/YspritanHyzygy/PP-OCR-for-Apple/releases/download/v\(version)/"
    )!

    static let detectorFileName = "VertoTextDetector.mlpackage"
    static let recognizerFileName = "VertoTextRecognizer.mlpackage"
    static let charactersFileName = "charset.txt"

    /// 检测输入固定 960×960（letterbox 补边）。固定形状是神经引擎的前提，
    /// 动态形状会让 Core ML 退回 CPU/GPU。
    static let detectorInputSize = 960
    /// 识别输入固定 48×640（13.3:1）。更窄的行右侧补零，更宽的按比例压进来。
    static let recognizerInputHeight = 48
    static let recognizerInputWidth = 640

    /// 检测预处理：ImageNet 均值方差。识别预处理：(x - 0.5) / 0.5。
    /// 两者都照搬 PaddleOCR 官方配置，改一个数就会让准确率断崖下跌。
    static let detectorMean: (Float, Float, Float) = (0.485, 0.456, 0.406)
    static let detectorStd: (Float, Float, Float) = (0.229, 0.224, 0.225)
    static let recognizerMean: Float = 0.5
    static let recognizerStd: Float = 0.5

    /// 模型落在 Application Support 而不是 Caches：Caches 会被系统在
    /// 磁盘紧张时静默清掉，用户会莫名其妙发现识别退回了系统引擎。
    /// 同时标记为不参与 iCloud 备份——它是可重新下载的派生数据。
    static func installDirectory(for tier: OCRModelTier) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return base
            .appendingPathComponent("OCRModels", isDirectory: true)
            .appendingPathComponent("v\(version)", isDirectory: true)
            .appendingPathComponent(tier.rawValue, isDirectory: true)
    }
}
