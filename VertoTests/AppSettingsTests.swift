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

final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultValues() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.translationEngine, .google)
        XCTAssertFalse(settings.autoSpeaksTranslation)
        XCTAssertEqual(settings.voicePlaybackMode, .speakAfterTranslation)
        XCTAssertEqual(settings.appearanceMode, .system)
        XCTAssertNil(settings.lastSourceLanguageCode)
        XCTAssertNil(settings.lastTargetLanguageCode)
        XCTAssertNil(settings.storedSourceLanguage)
        XCTAssertNil(settings.storedTargetLanguage)
    }

    func testRoundTripPersistence() {
        let settings = AppSettings(defaults: defaults)
        settings.autoSpeaksTranslation = true
        settings.voicePlaybackMode = .speakOnlyWithHeadphones
        settings.appearanceMode = .dark
        settings.lastSourceLanguageCode = "en"
        settings.lastTargetLanguageCode = "zh-Hans"

        let reloaded = AppSettings(defaults: defaults)

        XCTAssertEqual(reloaded.translationEngine, .google)
        XCTAssertTrue(reloaded.autoSpeaksTranslation)
        XCTAssertEqual(reloaded.voicePlaybackMode, .speakOnlyWithHeadphones)
        XCTAssertEqual(reloaded.appearanceMode, .dark)
        XCTAssertEqual(reloaded.storedSourceLanguage, .english)
        XCTAssertEqual(reloaded.storedTargetLanguage, .chinese)
    }

    func testUnknownVoicePlaybackModeFallsBackToDefault() {
        defaults.set("shout", forKey: "settings.voicePlaybackMode")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.voicePlaybackMode, .speakAfterTranslation)
    }

    func testUnknownAppearanceModeFallsBackToSystem() {
        defaults.set("sepia", forKey: "settings.appearanceMode")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.appearanceMode, .system)
    }

    func testUnknownEngineRawValueFallsBackToGoogle() {
        defaults.set("bing", forKey: "settings.translationEngine")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.translationEngine, .google)
    }

    func testStoredLanguageResolution() {
        let settings = AppSettings(defaults: defaults)

        settings.lastSourceLanguageCode = "auto"
        XCTAssertEqual(settings.storedSourceLanguage, .auto)

        settings.lastSourceLanguageCode = "xx"
        XCTAssertNil(settings.storedSourceLanguage)

        settings.lastSourceLanguageCode = nil
        XCTAssertNil(settings.storedSourceLanguage)
        XCTAssertNil(defaults.string(forKey: "settings.lastSourceLanguageCode"))
    }

    func testOnlyAvailableEnginesAreSelectableInCatalog() {
        XCTAssertEqual(TranslationEngine.allCases.filter(\.isAvailable), [.google])
    }
}
