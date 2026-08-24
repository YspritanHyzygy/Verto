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

import XCTest
@testable import Verto

/// 本地化资源完整性：宿主 app bundle 里 5 个 lproj 齐全，代表性 key
/// （普通/格式/语言名各类）逐语言可解析且互异，en/es 复数格式正确。
/// key 与译文的全量对账在构建脚本层（stringsdata diff）完成，这里守回归。
final class LocalizationTests: XCTestCase {
    private static let languages = ["zh-Hans", "en", "ja", "ko", "es"]

    /// 覆盖各类 key：视图字面量、String(localized:) 属性、错误文案、
    /// 插值格式串、动态查表的分节标题、语言注解名。
    private static let representativeKeys = [
        "翻译",
        "翻译服务",
        "系统翻译",
        "源语言",
        "目标语言",
        "文字识别",
        "默认",
        "设置",
        "选择语言",
        "历史记录",
        "轻点开始对话",
        "网络连接失败，请检查网络后重试",
        "正在聆听 · %@ / %@",
        "正在下载语言模型 %lld%%",
        "使用%@讲话",
        "英语",
        "今天",
        "全部语言",
        "正在识别文字…",
        "未获得相机权限，请在系统设置中开启",
        "此设备无法识别这种语言，请选择其他语言",
        "翻译服务暂时不可用（HTTP %lld），请稍后重试",
        "这份构建的翻译服务令牌无效，请检查中转配置",
        "%@ · 版本 %@",
    ]

    private static let permissionKeys = [
        "NSCameraUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSSpeechRecognitionUsageDescription",
    ]

    private func bundle(for language: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj"),
            "缺少 \(language).lproj"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    func testAllLanguageBundlesResolveRepresentativeKeys() throws {
        for language in Self.languages {
            let bundle = try bundle(for: language)
            for key in Self.representativeKeys {
                let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
                XCTAssertNotEqual(value, "__MISSING__", "\(language) 缺少 key：\(key)")
                XCTAssertFalse(value.isEmpty, "\(language) 的 \(key) 译文为空")
            }
        }
    }

    func testAllLanguageBundlesResolvePermissionDescriptions() throws {
        for language in Self.languages {
            let bundle = try bundle(for: language)
            for key in Self.permissionKeys {
                let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: "InfoPlist")
                XCTAssertNotEqual(value, "__MISSING__", "\(language) 缺少 InfoPlist key：\(key)")
                XCTAssertFalse(value.isEmpty, "\(language) 的 \(key) 文案为空")
                XCTAssertFalse(value.contains("iOS 26"), "\(language) 的权限文案写死了系统版本：\(value)")
            }
        }
    }

    func testLanguagesProduceDistinctTranslations() throws {
        for key in ["翻译", "选择语言"] {
            var seen: [String: String] = [:]
            for language in Self.languages {
                let value = try bundle(for: language)
                    .localizedString(forKey: key, value: "__MISSING__", table: nil)
                if let (otherLanguage, duplicate) = seen.first(where: { $0.value == value }) {
                    XCTFail("\(key) 在 \(language) 与 \(otherLanguage) 译文相同：\(duplicate)")
                }
                seen[language] = value
            }
            // 非中文语言的译文不应回退成 key 本身。
            for (language, value) in seen where language != "zh-Hans" {
                XCTAssertNotEqual(value, key, "\(language) 的 \(key) 回退到了源文")
            }
        }
    }

    func testPluralCharacterCountFormats() throws {
        // locale 参数决定 stringsdict 复数规则的选取，与测试进程语言无关。
        let cases: [(language: String, locale: String, one: String, other: String)] = [
            ("en", "en", "1 character", "2 characters"),
            ("es", "es", "1 carácter", "2 caracteres"),
        ]
        for testCase in cases {
            let format = try bundle(for: testCase.language)
                .localizedString(forKey: "%lld 字", value: nil, table: nil)
            let locale = Locale(identifier: testCase.locale)
            XCTAssertEqual(String(format: format, locale: locale, 1), testCase.one)
            XCTAssertEqual(String(format: format, locale: locale, 2), testCase.other)
        }
    }

    func testLocalizedLanguageNamesFollowCatalog() throws {
        // Language 的注解名走 String(localized:)；测试进程钉在 zh-Hans，
        // 应与目录中的 zh-Hans 值（即 key 本身）一致。
        XCTAssertEqual(Language.english.localizedName, "英语")
        XCTAssertEqual(Language.auto.nativeName, "自动检测")

        let englishBundle = try bundle(for: "en")
        XCTAssertEqual(
            englishBundle.localizedString(forKey: "英语", value: nil, table: nil),
            "English"
        )
    }
}
