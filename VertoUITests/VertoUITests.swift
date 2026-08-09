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

final class VertoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTextDictationProducesResultAndFavoriteAppearsInHistory() throws {
        let app = launchApp(mode: "text")

        let sourceEditor = element("source-text-editor", in: app)
        let translationResult = element("translation-result", in: app)
        let clearButton = element("clear-source-button", in: app)
        let dictationButton = element("dictation-button", in: app)
        let finishButton = element("finish-source-editing-button", in: app)

        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 3))
        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(clearButton.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilAbsent(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 0)
        clearButton.tap()

        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", ""), on: sourceEditor))
        XCTAssertFalse(translationResult.isEnabled)

        XCTAssertTrue(dictationButton.waitForExistence(timeout: 2))
        dictationButton.tap()

        XCTAssertTrue(wait(for: NSPredicate(format: "value != %@", ""), on: sourceEditor, timeout: 4))
        let dictatedSource = try XCTUnwrap(sourceEditor.value as? String)
        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertEqual(finishButton.label, "完成并翻译")
        XCTAssertTrue(waitUntilAbsent(translationResult))
        finishButton.tap()

        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "enabled == YES"), on: translationResult))
        let translatedResult = try XCTUnwrap(translationResult.value as? String)
        XCTAssertTrue(waitUntilAbsent(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 0)

        let favoriteButton = element("favorite-result-button", in: app)
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 2))
        XCTAssertEqual(favoriteButton.label, "收藏译文")
        favoriteButton.tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "取消收藏"), on: favoriteButton))

        let historyButton = element("history-button", in: app)
        XCTAssertTrue(historyButton.waitForExistence(timeout: 2))
        historyButton.tap()

        XCTAssertTrue(app.staticTexts["历史记录"].waitForExistence(timeout: 3))
        let todaySection = app.staticTexts["今天"].firstMatch
        let yesterdaySection = app.staticTexts["昨天"].firstMatch
        XCTAssertTrue(todaySection.waitForExistence(timeout: 2))
        XCTAssertTrue(yesterdaySection.waitForExistence(timeout: 2))
        XCTAssertLessThan(todaySection.frame.minY, yesterdaySection.frame.minY)
        captureScreenshot(named: "history-native-list", of: app)

        let allFilter = element("history-all-filter", in: app)
        let favoritesFilter = element("history-favorites-filter", in: app)
        XCTAssertTrue(allFilter.waitForExistence(timeout: 2))
        XCTAssertTrue(favoritesFilter.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(allFilter))
        XCTAssertTrue(waitUntilDeselected(favoritesFilter))
        favoritesFilter.tap()
        XCTAssertTrue(waitUntilSelected(favoritesFilter))
        XCTAssertTrue(waitUntilDeselected(allFilter))
        captureScreenshot(named: "history-native-filter-picker", of: app)

        let savedHistoryItem = app.buttons
            .matching(NSPredicate(format: "label == %@", "载入翻译：\(dictatedSource)"))
            .firstMatch
        XCTAssertTrue(savedHistoryItem.waitForExistence(timeout: 3))

        let historyFavoriteButtons = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "history-favorite-"))
        XCTAssertTrue(historyFavoriteButtons.firstMatch.waitForExistence(timeout: 2))
        let favoriteButtonIdentifiers = (0..<historyFavoriteButtons.count).map {
            historyFavoriteButtons.element(boundBy: $0).identifier
        }
        for identifier in favoriteButtonIdentifiers {
            let removeFavoriteButton = element(identifier, in: app)
            XCTAssertTrue(removeFavoriteButton.waitForExistence(timeout: 2))
            removeFavoriteButton.tap()
            XCTAssertTrue(waitUntilAbsent(removeFavoriteButton))
        }

        let emptyState = element("history-empty-state", in: app)
        XCTAssertTrue(emptyState.waitForExistence(timeout: 2))
        captureScreenshot(named: "history-native-empty-state", of: app)

        allFilter.tap()
        XCTAssertTrue(waitUntilSelected(allFilter))
        XCTAssertTrue(waitUntilDeselected(favoritesFilter))
        XCTAssertTrue(waitUntilAbsent(emptyState))
        XCTAssertTrue(savedHistoryItem.waitForExistence(timeout: 3))
        savedHistoryItem.tap()

        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", dictatedSource), on: sourceEditor))
        // 历史条目只保存主译文，没有备选译法，结果按钮保持禁用；断言译文内容被正确回填。
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", translatedResult), on: translationResult))
    }

    @MainActor
    func testTextDraftWaitsForFinishBeforeTranslatingAndRestoresNavigation() throws {
        let app = launchApp(mode: "text")

        let sourceEditor = element("source-text-editor", in: app)
        let translationResult = element("translation-result", in: app)
        let clearButton = element("clear-source-button", in: app)
        let finishButton = element("finish-source-editing-button", in: app)
        let sourceLanguageButton = element("language-pair-source-button", in: app)
        let swapLanguageButton = element("language-pair-swap-button", in: app)
        let targetLanguageButton = element("language-pair-target-button", in: app)
        let tabBar = app.tabBars.firstMatch
        let textMode = tabBar.buttons["文字"]

        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 3))
        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilAbsent(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 0)

        sourceEditor.tap()

        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertEqual(finishButton.label, "完成并翻译")
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 1)
        XCTAssertTrue(waitUntilAbsent(tabBar))
        XCTAssertTrue(waitUntilAbsent(translationResult))

        finishButton.tap()

        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(
            for: NSPredicate(
                format: "value == %@",
                "The sunset is especially beautiful today — I'd love to take a walk along the beach with you."
            ),
            on: translationResult
        ))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(textMode.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(textMode))
        XCTAssertTrue(wait(
            for: NSPredicate(
                format: "value == %@",
                "今天的晚霞特别好看，我想和你一起去海边走走。"
            ),
            on: sourceEditor
        ))
        XCTAssertTrue(waitUntilAbsent(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 0)

        sourceEditor.tap()

        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilHittable(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 1)
        XCTAssertTrue(waitUntilAbsent(tabBar))
        XCTAssertTrue(waitUntilAbsent(translationResult))

        XCTAssertTrue(clearButton.waitForExistence(timeout: 2))
        clearButton.tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", ""), on: sourceEditor))

        sourceEditor.typeText("First line\nSecond line")
        XCTAssertTrue(wait(
            for: NSPredicate(format: "value == %@", "First line\nSecond line"),
            on: sourceEditor
        ))
        XCTAssertTrue(finishButton.exists)
        XCTAssertTrue(waitUntilAbsent(tabBar))
        XCTAssertTrue(waitUntilAbsent(translationResult))

        clearButton.tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", ""), on: sourceEditor))

        sourceEditor.typeText("Good morning")
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", "Good morning"), on: sourceEditor))
        XCTAssertTrue(waitUntilAbsent(translationResult))
        captureScreenshot(named: "text-draft-keyboard", of: app)

        XCTAssertTrue(targetLanguageButton.waitForExistence(timeout: 2))
        targetLanguageButton.tap()

        XCTAssertTrue(app.staticTexts["选择语言"].waitForExistence(timeout: 3))
        let japanese = element("languagePicker.language.ja", in: app)
        XCTAssertTrue(japanese.waitForExistence(timeout: 3))
        japanese.tap()

        XCTAssertFalse(app.staticTexts["选择语言"].waitForExistence(timeout: 2))
        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilHittable(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 1)
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", "Good morning"), on: sourceEditor))
        sourceEditor.typeText("!")
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", "Good morning!"), on: sourceEditor))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "中文"), on: sourceLanguageButton))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "日本語"), on: targetLanguageButton))
        XCTAssertTrue(waitUntilAbsent(tabBar))
        XCTAssertTrue(waitUntilAbsent(translationResult))

        XCTAssertTrue(swapLanguageButton.waitForExistence(timeout: 2))
        swapLanguageButton.tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "日本語"), on: sourceLanguageButton))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "中文"), on: targetLanguageButton))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", "Good morning!"), on: sourceEditor))
        XCTAssertTrue(waitUntilAbsent(translationResult))

        swapLanguageButton.tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "中文"), on: sourceLanguageButton))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "日本語"), on: targetLanguageButton))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", "Good morning!"), on: sourceEditor))
        XCTAssertTrue(waitUntilAbsent(tabBar))
        XCTAssertTrue(waitUntilAbsent(translationResult))
        captureScreenshot(named: "text-draft-focused", of: app)

        finishButton.tap()

        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "enabled == YES"), on: translationResult))
        XCTAssertTrue(wait(
            for: NSPredicate(format: "value == %@", "「Good morning!」の自然な翻訳"),
            on: translationResult
        ))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))

        XCTAssertTrue(textMode.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(textMode))

        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "日本語"), on: targetLanguageButton))
        XCTAssertTrue(waitUntilAbsent(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 0)
        captureScreenshot(named: "text-draft-result", of: app)
    }

    @MainActor
    func testAlternativeTranslationSelectionUpdatesResultAndDismissesSheet() throws {
        let app = launchApp(mode: "text")
        let translationResult = element("translation-result", in: app)

        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "enabled == YES"), on: translationResult))
        let initialResult = try XCTUnwrap(translationResult.value as? String)

        translationResult.tap()

        let secondAlternative = element("alternative-2", in: app)
        XCTAssertTrue(secondAlternative.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilHittable(secondAlternative))
        captureScreenshot(named: "alternative-translations-list", of: app)
        secondAlternative.tap()

        XCTAssertTrue(waitUntilAbsent(secondAlternative))
        XCTAssertTrue(wait(
            for: NSPredicate(format: "value != %@", initialResult),
            on: translationResult
        ))
    }

    @MainActor
    func testReduceMotionTextEntryCompletesInStableResultState() throws {
        let app = launchApp(mode: "text", reduceMotion: true)

        let sourceEditor = element("source-text-editor", in: app)
        let translationResult = element("translation-result", in: app)
        let finishButton = element("finish-source-editing-button", in: app)
        let historyButton = element("history-button", in: app)
        let tabBar = app.tabBars.firstMatch
        let textMode = tabBar.buttons["文字"]

        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 3))
        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilAbsent(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 0)

        sourceEditor.tap()

        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertEqual(finishButton.label, "完成并翻译")
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 1)
        XCTAssertTrue(waitUntilAbsent(translationResult))
        XCTAssertTrue(waitUntilAbsent(tabBar))

        finishButton.tap()

        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(
            for: NSPredicate(
                format: "value == %@",
                "The sunset is especially beautiful today — I'd love to take a walk along the beach with you."
            ),
            on: translationResult
        ))
        XCTAssertTrue(wait(
            for: NSPredicate(
                format: "value == %@",
                "今天的晚霞特别好看，我想和你一起去海边走走。"
            ),
            on: sourceEditor
        ))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(textMode.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(textMode))
        XCTAssertTrue(historyButton.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilAbsent(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 0)
    }

    @MainActor
    func testTextEntryPaperMotionRendersIntermediateFrames() throws {
        let app = launchApp(mode: "text", motionProbe: true)
        let probe = element("text-entry-motion-probe", in: app)
        let sourceEditor = element("source-text-editor", in: app)
        let finishButton = element("finish-source-editing-button", in: app)

        XCTAssertTrue(probe.waitForExistence(timeout: 3))
        XCTAssertTrue(
            wait(
                for: NSPredicate(format: "value CONTAINS %@", "reduce=0"),
                on: probe
            ),
            "Probe: \(String(describing: probe.value))"
        )
        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 3))

        sourceEditor.tap()

        XCTAssertTrue(
            wait(
                for: NSPredicate(format: "value CONTAINS %@", "enter-pass=1"),
                on: probe,
                timeout: 4
            ),
            "Probe: \(String(describing: probe.value))"
        )
        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilHittable(finishButton))

        finishButton.tap()

        XCTAssertTrue(
            wait(
                for: NSPredicate(format: "value CONTAINS %@", "exit-pass=1"),
                on: probe,
                timeout: 4
            ),
            "Probe: \(String(describing: probe.value))"
        )
    }

    @MainActor
    func testLanguageSearchAndTargetSelection() throws {
        let app = launchApp(mode: "text", sheet: "language-target")

        XCTAssertTrue(app.staticTexts["选择语言"].waitForExistence(timeout: 3))
        let searchField = element("languagePicker.searchField", in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.tap()
        searchField.typeText("ja")

        let japanese = element("languagePicker.language.ja", in: app)
        XCTAssertTrue(japanese.waitForExistence(timeout: 3))
        japanese.tap()

        XCTAssertFalse(app.staticTexts["选择语言"].waitForExistence(timeout: 2))
        let selectedTarget = app.buttons
            .matching(NSPredicate(format: "label == %@", "日本語"))
            .firstMatch
        XCTAssertTrue(selectedTarget.waitForExistence(timeout: 3))
    }

    @MainActor
    func testLanguageListSectionsScrollAndSourceSelection() throws {
        let app = launchApp(mode: "text", sheet: "language-source")

        let title = app.staticTexts["选择语言"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let list = element("languagePicker.list", in: app)
        let autoDetect = element("languagePicker.language.auto", in: app)
        let recentSection = app.staticTexts["最近使用"].firstMatch
        let english = element("languagePicker.language.en", in: app)
        let chinese = element("languagePicker.language.zh-Hans", in: app)
        let allLanguagesSection = app.staticTexts["全部语言"].firstMatch
        let japanese = element("languagePicker.language.ja", in: app)

        XCTAssertTrue(list.waitForExistence(timeout: 2))
        XCTAssertTrue(autoDetect.waitForExistence(timeout: 2))
        XCTAssertTrue(recentSection.waitForExistence(timeout: 2))
        XCTAssertTrue(english.waitForExistence(timeout: 2))
        XCTAssertTrue(chinese.waitForExistence(timeout: 2))
        XCTAssertTrue(allLanguagesSection.waitForExistence(timeout: 2))
        XCTAssertTrue(japanese.waitForExistence(timeout: 2))
        XCTAssertLessThan(autoDetect.frame.minY, recentSection.frame.minY)
        XCTAssertLessThan(recentSection.frame.minY, english.frame.minY)
        XCTAssertLessThan(english.frame.minY, chinese.frame.minY)
        XCTAssertLessThan(chinese.frame.minY, allLanguagesSection.frame.minY)
        XCTAssertLessThan(allLanguagesSection.frame.minY, japanese.frame.minY)
        captureScreenshot(named: "language-native-list-top", of: app)

        let german = element("languagePicker.language.de", in: app)
        XCTAssertTrue(german.waitForExistence(timeout: 2))
        let titleY = title.frame.minY
        let germanY = german.frame.minY
        let dragStart = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let dragEnd = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        XCTAssertLessThan(german.frame.minY, germanY)
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1)
        XCTAssertTrue(waitUntilHittable(german))
        captureScreenshot(named: "language-native-list-scrolled", of: app)
        german.tap()

        XCTAssertFalse(title.waitForExistence(timeout: 2))
        let selectedSource = element("language-pair-source-button", in: app)
        XCTAssertTrue(selectedSource.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "Deutsch"), on: selectedSource))
    }

    @MainActor
    func testVoiceListeningProducesCommittedTurnThenPauses() throws {
        let app = launchApp(mode: "voice")

        XCTAssertTrue(waitUntilSelected(tabButton(named: "语音", in: app)))
        let microphone = element("conversation-microphone-button", in: app)
        let listeningStatus = element("conversation-listening-status", in: app)
        XCTAssertTrue(microphone.waitForExistence(timeout: 3))
        XCTAssertTrue(listeningStatus.waitForExistence(timeout: 3))
        // 生产版从空白待机开始，不再自动聆听。
        XCTAssertTrue(element("conversation-empty-hint", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "轻点开始对话"), on: listeningStatus))
        XCTAssertEqual(microphone.label, "开始聆听")

        microphone.tap()
        // 脚本化语音（--uitest-canned-speech）：volatile → final，
        // 定稿后按固定译文表提交为对话气泡，随后自动续听。
        let committedOriginal = firstElement(containingLabel: "Good morning", in: app)
        XCTAssertTrue(committedOriginal.waitForExistence(timeout: 6))
        let committedTranslation = firstElement(containingLabel: "早上好", in: app)
        XCTAssertTrue(committedTranslation.waitForExistence(timeout: 3))
        // 自动检测模式：状态显示语言对双语。
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "正在聆听 · English / 中文"), on: listeningStatus, timeout: 6))

        microphone.tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "已暂停 · 轻点继续"), on: listeningStatus, timeout: 6))
        XCTAssertEqual(microphone.label, "开始聆听")
    }

    @MainActor
    func testSettingsVoicePlaybackModeSelection() throws {
        let app = launchApp(mode: "text", sheet: "settings")

        let speakAfter = element("settings.voicePlayback.speakAfterTranslation", in: app)
        let textOnly = element("settings.voicePlayback.textOnly", in: app)
        let headphonesOnly = element("settings.voicePlayback.speakOnlyWithHeadphones", in: app)
        XCTAssertTrue(speakAfter.waitForExistence(timeout: 3))
        XCTAssertTrue(textOnly.waitForExistence(timeout: 2))
        XCTAssertTrue(headphonesOnly.waitForExistence(timeout: 2))

        // 默认选中「翻译完自动朗读」。
        XCTAssertEqual(speakAfter.value as? String, "已选择")

        textOnly.tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", "已选择"), on: textOnly))
        XCTAssertEqual(speakAfter.value as? String, "")
    }

    @MainActor
    func testCameraShutterShowsRecognizedMenuResults() throws {
        let app = launchApp(mode: "camera")

        XCTAssertTrue(waitUntilSelected(tabButton(named: "相机", in: app)))
        let gallery = element("camera.galleryPicker", in: app)
        let shutter = element("camera.shutterButton", in: app)
        let flash = element("camera.flashButton", in: app)
        XCTAssertTrue(gallery.waitForExistence(timeout: 3))
        XCTAssertTrue(shutter.waitForExistence(timeout: 3))
        XCTAssertTrue(flash.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilHittable(gallery))
        XCTAssertTrue(waitUntilHittable(shutter))
        XCTAssertTrue(waitUntilHittable(flash))

        let tabBarFrame = app.tabBars.firstMatch.frame
        XCTAssertFalse(gallery.frame.intersects(tabBarFrame))
        XCTAssertFalse(shutter.frame.intersects(tabBarFrame))
        XCTAssertFalse(flash.frame.intersects(tabBarFrame))
        shutter.tap()

        // As with voice processing, the loading state completes before XCUI's
        // post-tap idle wait returns. Verify the stable recognized state and data.
        let recognizedTitle = element("camera.recognitionTitle", in: app)
        XCTAssertTrue(recognizedTitle.waitForExistence(timeout: 4))
        XCTAssertTrue(shutter.isEnabled)

        let recognizedResult = firstElement(containingLabel: "Braised Beef Noodles", in: app)
        XCTAssertTrue(recognizedResult.waitForExistence(timeout: 2))
    }

    @MainActor
    func testBottomNavigationPersistsAcrossEveryMode() throws {
        let app = launchApp(mode: "text")

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))

        let textMode = tabBar.buttons["文字"]
        let voiceMode = tabBar.buttons["语音"]
        let cameraMode = tabBar.buttons["相机"]

        assertTabBarExists(tabBar: tabBar, text: textMode, voice: voiceMode, camera: cameraMode)
        XCTAssertTrue(waitUntilSelected(textMode))

        voiceMode.tap()
        let microphone = element("conversation-microphone-button", in: app)
        let listeningStatus = element("conversation-listening-status", in: app)
        XCTAssertTrue(microphone.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilSelected(voiceMode))
        XCTAssertTrue(waitUntilDeselected(textMode))
        assertTabBarExists(tabBar: tabBar, text: textMode, voice: voiceMode, camera: cameraMode)
        captureScreenshot(named: "native-tab-voice", of: app)

        microphone.tap()
        // 开始聆听后切走 tab：语音页会停止收音并记住暂停态。
        XCTAssertTrue(wait(for: NSPredicate(format: "label BEGINSWITH %@", "正在"), on: listeningStatus, timeout: 6))

        cameraMode.tap()
        let shutter = element("camera.shutterButton", in: app)
        XCTAssertTrue(shutter.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilHittable(shutter))
        XCTAssertTrue(waitUntilSelected(cameraMode))
        XCTAssertTrue(waitUntilDeselected(voiceMode))
        assertTabBarExists(tabBar: tabBar, text: textMode, voice: voiceMode, camera: cameraMode)
        captureScreenshot(named: "native-tab-camera", of: app)

        voiceMode.tap()
        XCTAssertTrue(waitUntilSelected(voiceMode))
        let restoredListeningStatus = element("conversation-listening-status", in: app)
        let restoredMicrophone = element("conversation-microphone-button", in: app)
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "已暂停 · 轻点继续"), on: restoredListeningStatus, timeout: 6))
        XCTAssertEqual(restoredMicrophone.label, "开始聆听")

        textMode.tap()
        XCTAssertTrue(element("source-text-editor", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilSelected(textMode))
        XCTAssertTrue(waitUntilDeselected(voiceMode))
        assertTabBarExists(tabBar: tabBar, text: textMode, voice: voiceMode, camera: cameraMode)
        captureScreenshot(named: "native-tab-text", of: app)
    }

    /// 英文界面冒烟：本地化目录真实生效（标题、tab、历史表头都不再是中文）。
    /// 其余测试经 launchApp 默认参数钉在 zh-Hans，断言不受本地化影响。
    @MainActor
    func testEnglishLocalizationSmoke() throws {
        let app = launchApp(mode: "text", language: "en", locale: "en_US")

        XCTAssertTrue(app.staticTexts["Translate"].waitForExistence(timeout: 3))
        XCTAssertTrue(tabButton(named: "Text", in: app).exists)

        let historyButton = element("history-button", in: app)
        XCTAssertTrue(historyButton.waitForExistence(timeout: 2))
        XCTAssertEqual(historyButton.label, "History")
        historyButton.tap()
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func launchApp(
        mode: String,
        sheet: String? = nil,
        reduceMotion: Bool = false,
        motionProbe: Bool = false,
        language: String = "zh-Hans",
        locale: String = "zh_Hans_CN"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            "--uitest-mode", mode,
            // 固定演示译文/脚本化语音并复位持久化偏好，
            // UI 测试不碰真实网络、麦克风与 TTS，不受上次运行影响。
            "--uitest-canned-translation",
            "--uitest-canned-speech",
            "--uitest-reset-settings"
        ]
        if let sheet {
            app.launchArguments.append(contentsOf: ["--uitest-sheet", sheet])
        }
        if reduceMotion {
            app.launchArguments.append("--ui-testing-reduce-motion")
        }
        if motionProbe {
            app.launchArguments.append("--ui-testing-text-entry-motion-probe")
        }
        addTeardownBlock {
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func firstElement(containingLabel text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    @MainActor
    private func tabButton(named title: String, in app: XCUIApplication) -> XCUIElement {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        let button = tabBar.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        return button
    }

    @MainActor
    private func assertTabBarExists(
        tabBar: XCUIElement,
        text: XCUIElement,
        voice: XCUIElement,
        camera: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(tabBar.exists, file: file, line: line)
        XCTAssertTrue(text.waitForExistence(timeout: 2), file: file, line: line)
        XCTAssertTrue(voice.waitForExistence(timeout: 2), file: file, line: line)
        XCTAssertTrue(camera.waitForExistence(timeout: 2), file: file, line: line)
    }

    @MainActor
    private func waitUntilSelected(_ element: XCUIElement) -> Bool {
        wait(for: NSPredicate(format: "selected == YES"), on: element)
    }

    @MainActor
    private func waitUntilDeselected(_ element: XCUIElement) -> Bool {
        wait(for: NSPredicate(format: "selected == NO"), on: element)
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement) -> Bool {
        wait(for: NSPredicate(format: "hittable == YES"), on: element)
    }

    @MainActor
    private func waitUntilAbsent(_ element: XCUIElement) -> Bool {
        wait(for: NSPredicate(format: "exists == NO"), on: element)
    }

    @MainActor
    private func elementCount(_ identifier: String, in app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .count
    }

    @MainActor
    private func captureScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func wait(
        for predicate: NSPredicate,
        on object: Any,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
