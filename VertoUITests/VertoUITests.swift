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

/// 所有「等界面落到某个状态」的断言共用这一个上限。
///
/// 为什么不是 3 秒：`waitUntilSelected/Deselected/Hittable` 走
/// `XCTNSPredicateExpectation`，而 `XCUIElement` 的 `selected`/`hittable`
/// 不支持 KVO，谓词只能被周期性重算，每次重算都要拍一次无障碍树快照。
/// 实测（4 worker 并行、结果包 verto-base-1.xcresult）单次求值耗时
/// 1.5–2.3 秒，3 秒预算只够 1–2 次采样：外观选择器点击后，新选中行 665 行
/// 断言通过，旧选中行 666 行却在 2.31 秒后判负——而 4 秒时同一状态已经正常。
/// 状态是到的，只是没赶上采样窗口。
///
/// 为什么是 10 秒：app 里最长的过渡是 0.45 秒的展开弹簧，翻译与语音都由
/// `--uitest-canned-*` 同步返回，语义上需要的预算不到 1 秒；10 秒是纯粹的
/// 负载余量。它只是失败判定的截止线——条件一成立立刻返回，**绿色路径上一
/// 毫秒都不多花**，真坏了也照样在 10 秒内报错。
private let settleTimeout: TimeInterval = 10

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

        XCTAssertTrue(wait(for: NSPredicate(format: "value != %@", ""), on: sourceEditor))
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
        let initialSource = try XCTUnwrap(sourceEditor.value as? String)
        let initialResult = try XCTUnwrap(translationResult.value as? String)
        XCTAssertFalse(initialSource.isEmpty)
        XCTAssertFalse(initialResult.isEmpty)

        sourceEditor.tap()

        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertEqual(finishButton.label, "完成并翻译")
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 1)
        // 这里等的是 UIKit 落地 .toolbar(.hidden, for: .tabBar) 的安全区变更——系统异步
        // 执行，见 TextTranslateView.swift 顶部关于标签栏安全区的注释。本文件只有这类
        // 紧跟编辑态切换的位置才等系统事件；其余「仍然隐藏」的复检用瞬时 exists，
        // 免得截止线把弹窗关闭时工具栏短暂回插这种回归悄悄吸收掉。
        XCTAssertTrue(waitUntilAbsent(tabBar))
        XCTAssertTrue(waitUntilAbsent(translationResult))

        finishButton.tap()

        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", initialResult), on: translationResult))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(textMode.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(textMode))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", initialSource), on: sourceEditor))
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
        XCTAssertFalse(tabBar.exists)
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

        XCTAssertTrue(app.staticTexts["选择语言"].waitForNonExistence(timeout: settleTimeout))
        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilHittable(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 1)
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", "Good morning"), on: sourceEditor))
        sourceEditor.typeText("!")
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", "Good morning!"), on: sourceEditor))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "中文"), on: sourceLanguageButton))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "日本語"), on: targetLanguageButton))
        XCTAssertFalse(tabBar.exists)
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
        XCTAssertFalse(tabBar.exists)
        XCTAssertTrue(waitUntilAbsent(translationResult))
        captureScreenshot(named: "text-draft-focused", of: app)

        finishButton.tap()

        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "enabled == YES"), on: translationResult))
        XCTAssertTrue(wait(for: NSPredicate(format: "value != %@", initialResult), on: translationResult))
        let updatedResult = try XCTUnwrap(translationResult.value as? String)
        XCTAssertFalse(updatedResult.isEmpty)
        // 目标语言已切到日语，所以断言译文"确实是日语"，而不是断言某句固定译文
        // （钉字面值就是把假数据当规格）。只查"变了且非空"时，路由忽略目标语言、
        // 把英文原样回填也会通过。用假名区间而不是 NLLanguageRecognizer：实测后者
        // 对「Good morning!」の自然な翻訳 这类内嵌英文的短句判成 en。
        XCTAssertNotNil(
            updatedResult.rangeOfCharacter(from: .japaneseKana),
            "目标语言为日语时译文应含假名，实际为：\(updatedResult)"
        )
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
        // 先记下这一行当时显示的文案，待会儿拿它当预期值：契约是"选了哪条译法，
        // 结果就变成哪条"，只断言"变了"的话，换成任意另一条译法也会通过。
        // 行 label 是序号加译文的组合，所以比对方向是 label 包含新结果。
        let chosenRowLabel = secondAlternative.label
        XCTAssertFalse(chosenRowLabel.isEmpty)
        secondAlternative.tap()

        XCTAssertTrue(waitUntilAbsent(secondAlternative))
        XCTAssertTrue(wait(
            for: NSPredicate(format: "value != %@", initialResult),
            on: translationResult
        ))
        let updatedResult = try XCTUnwrap(translationResult.value as? String)
        XCTAssertFalse(updatedResult.isEmpty)
        XCTAssertTrue(
            chosenRowLabel.contains(updatedResult),
            "结果应为所选译法，所选行为「\(chosenRowLabel)」，实际结果为「\(updatedResult)」"
        )
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
        let initialSource = try XCTUnwrap(sourceEditor.value as? String)
        let initialResult = try XCTUnwrap(translationResult.value as? String)
        XCTAssertFalse(initialSource.isEmpty)
        XCTAssertFalse(initialResult.isEmpty)

        sourceEditor.tap()

        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertEqual(finishButton.label, "完成并翻译")
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 1)
        XCTAssertTrue(waitUntilAbsent(translationResult))
        XCTAssertTrue(waitUntilAbsent(tabBar))

        finishButton.tap()

        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", initialResult), on: translationResult))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", initialSource), on: sourceEditor))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(textMode.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(textMode))
        XCTAssertTrue(historyButton.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilAbsent(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 0)
    }

    @MainActor
    func testTextEntryTransitionsEnterAndExitStableStates() throws {
        let app = launchApp(mode: "text")
        let sourceEditor = element("source-text-editor", in: app)
        let translationResult = element("translation-result", in: app)
        let finishButton = element("finish-source-editing-button", in: app)
        let tabBar = app.tabBars.firstMatch
        let textMode = tabBar.buttons["文字"]

        XCTAssertTrue(sourceEditor.waitForExistence(timeout: 3))
        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilAbsent(finishButton))
        let initialSource = try XCTUnwrap(sourceEditor.value as? String)
        let initialResult = try XCTUnwrap(translationResult.value as? String)
        XCTAssertFalse(initialSource.isEmpty)
        XCTAssertFalse(initialResult.isEmpty)

        sourceEditor.tap()

        XCTAssertTrue(finishButton.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilHittable(finishButton))
        XCTAssertTrue(waitUntilAbsent(translationResult))
        XCTAssertTrue(waitUntilAbsent(tabBar))
        captureScreenshot(named: "text-entry-entered", of: app)

        finishButton.tap()

        XCTAssertTrue(translationResult.waitForExistence(timeout: 3))
        XCTAssertTrue(wait(for: NSPredicate(format: "enabled == YES"), on: translationResult))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", initialResult), on: translationResult))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", initialSource), on: sourceEditor))
        XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
        XCTAssertTrue(textMode.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(textMode))
        XCTAssertTrue(waitUntilAbsent(finishButton))
        XCTAssertEqual(elementCount("finish-source-editing-button", in: app), 0)
        captureScreenshot(named: "text-entry-final", of: app)
    }

    @MainActor
    func testLanguageSearchAndTargetSelection() throws {
        let app = launchApp(mode: "text", sheet: "language-target")

        XCTAssertTrue(app.staticTexts["选择语言"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("languagePicker.closeButton", in: app).waitForExistence(timeout: 2))
        let searchField = app.searchFields["搜索语言"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        XCTAssertEqual(app.searchFields.count, 1)
        searchField.tap()

        searchField.typeText("zzzz")
        let emptyTitle = app.staticTexts["未找到语言"]
        let emptyDescription = app.staticTexts["请尝试其他名称或语言代码"]
        let clearSearch = app.buttons["清除搜索"]
        XCTAssertTrue(emptyTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(emptyDescription.waitForExistence(timeout: 2))
        XCTAssertTrue(clearSearch.waitForExistence(timeout: 2))
        let languageRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "languagePicker.language.")
        )
        XCTAssertEqual(languageRows.count, 0)
        captureScreenshot(named: "language-native-empty-state", of: app)

        clearSearch.tap()
        XCTAssertTrue(waitUntilAbsent(emptyTitle))
        XCTAssertTrue(app.staticTexts["最近使用"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["全部语言"].waitForExistence(timeout: 2))
        for code in ["en", "zh-Hans", "ja", "ko", "fr", "es", "de"] {
            XCTAssertTrue(element("languagePicker.language.\(code)", in: app).waitForExistence(timeout: 2))
        }
        XCTAssertEqual(languageRows.count, 7)
        XCTAssertTrue(app.keyboards.firstMatch.exists)

        searchField.typeText("FRANCAIS")
        let french = element("languagePicker.language.fr", in: app)
        XCTAssertTrue(french.waitForExistence(timeout: 3))
        captureScreenshot(named: "language-native-search", of: app)

        let deleteKey = XCUIKeyboardKey.delete.rawValue
        searchField.typeText(String(repeating: deleteKey, count: 8))
        searchField.typeText("德语")
        XCTAssertTrue(waitUntilAbsent(french))
        let german = element("languagePicker.language.de", in: app)
        XCTAssertTrue(german.waitForExistence(timeout: 3))

        searchField.typeText(String(repeating: deleteKey, count: 2))
        searchField.typeText("JA")
        XCTAssertTrue(waitUntilAbsent(german))

        let japanese = element("languagePicker.language.ja", in: app)
        XCTAssertTrue(japanese.waitForExistence(timeout: 3))
        japanese.tap()

        XCTAssertTrue(app.staticTexts["选择语言"].waitForNonExistence(timeout: settleTimeout))
        let selectedTarget = app.buttons
            .matching(NSPredicate(format: "label == %@", "日本語"))
            .firstMatch
        XCTAssertTrue(selectedTarget.waitForExistence(timeout: 3))
    }

    @MainActor
    func testLanguageRolePickerKeepsSearchActiveAndUpdatesSourceSelection() throws {
        let app = launchApp(mode: "text", sheet: "language-target")

        let rolePicker = app.segmentedControls["languagePicker.roleSelector"].firstMatch
        XCTAssertTrue(rolePicker.waitForExistence(timeout: 3))
        let targetRole = rolePicker.buttons["翻译到"]
        let sourceRole = rolePicker.buttons["翻译自"]
        XCTAssertTrue(targetRole.waitForExistence(timeout: 2))
        XCTAssertTrue(sourceRole.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(targetRole))
        XCTAssertTrue(waitUntilDeselected(sourceRole))

        let searchField = app.searchFields["搜索语言"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        searchField.typeText("DE")
        let german = element("languagePicker.language.de", in: app)
        XCTAssertTrue(german.waitForExistence(timeout: 3))

        sourceRole.tap()
        XCTAssertTrue(waitUntilSelected(sourceRole))
        XCTAssertTrue(waitUntilDeselected(targetRole))
        XCTAssertTrue(wait(for: NSPredicate(format: "value == %@", "DE"), on: searchField))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(german.exists)
        captureScreenshot(named: "language-native-role-picker", of: app)
        german.tap()
        XCTAssertTrue(waitUntilAbsent(rolePicker))

        let selectedSource = element("language-pair-source-button", in: app)
        let unchangedTarget = element("language-pair-target-button", in: app)
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "Deutsch"), on: selectedSource))
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "English"), on: unchangedTarget))
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

        XCTAssertTrue(title.waitForNonExistence(timeout: settleTimeout))
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
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "正在聆听 · English / 中文"), on: listeningStatus))

        microphone.tap()
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "已暂停 · 轻点继续"), on: listeningStatus))
        XCTAssertEqual(microphone.label, "开始聆听")
    }

    @MainActor
    func testSettingsFormSectionsScrollAndVoicePlaybackSelection() throws {
        let app = launchApp(mode: "text", sheet: "settings")

        let form = element("settings.form", in: app)
        let closeButton = element("settings.closeButton", in: app)
        let engineSection = app.staticTexts["翻译模型"].firstMatch
        let googleEngine = app.buttons["settings.engine.google"].firstMatch
        let customEngine = app.buttons["settings.engine.custom"].firstMatch
        let llmEngine = app.buttons["settings.engine.llm"].firstMatch
        let voiceSection = app.staticTexts["语音对话"].firstMatch
        let speakAfter = app.buttons["settings.voicePlayback.speakAfterTranslation"].firstMatch
        let textOnly = app.buttons["settings.voicePlayback.textOnly"].firstMatch
        let headphonesOnly = app.buttons["settings.voicePlayback.speakOnlyWithHeadphones"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
        XCTAssertTrue(engineSection.waitForExistence(timeout: 2))
        XCTAssertTrue(googleEngine.waitForExistence(timeout: 2))
        XCTAssertTrue(customEngine.waitForExistence(timeout: 2))
        XCTAssertTrue(llmEngine.waitForExistence(timeout: 2))
        XCTAssertTrue(googleEngine.isEnabled)
        XCTAssertFalse(customEngine.isEnabled)
        XCTAssertFalse(llmEngine.isEnabled)
        XCTAssertTrue(waitUntilSelected(googleEngine))
        XCTAssertTrue(waitUntilDeselected(customEngine))
        XCTAssertTrue(waitUntilDeselected(llmEngine))
        XCTAssertTrue(customEngine.label.contains("即将推出"))
        XCTAssertTrue(llmEngine.label.contains("即将推出"))
        XCTAssertTrue(voiceSection.waitForExistence(timeout: 2))
        XCTAssertTrue(speakAfter.waitForExistence(timeout: 3))
        XCTAssertTrue(textOnly.waitForExistence(timeout: 2))
        XCTAssertTrue(headphonesOnly.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(speakAfter))
        XCTAssertTrue(waitUntilDeselected(textOnly))
        XCTAssertTrue(waitUntilDeselected(headphonesOnly))
        XCTAssertLessThan(engineSection.frame.minY, googleEngine.frame.minY)
        XCTAssertLessThan(googleEngine.frame.minY, customEngine.frame.minY)
        XCTAssertLessThan(customEngine.frame.minY, llmEngine.frame.minY)
        XCTAssertLessThan(llmEngine.frame.minY, voiceSection.frame.minY)
        XCTAssertLessThan(voiceSection.frame.minY, textOnly.frame.minY)
        XCTAssertLessThan(textOnly.frame.minY, speakAfter.frame.minY)
        XCTAssertLessThan(speakAfter.frame.minY, headphonesOnly.frame.minY)

        XCTAssertTrue(waitUntilHittable(textOnly))
        XCTAssertTrue(waitUntilHittable(speakAfter))
        XCTAssertTrue(waitUntilHittable(headphonesOnly))
        textOnly.tap()
        XCTAssertTrue(waitUntilSelected(textOnly))
        XCTAssertTrue(waitUntilDeselected(speakAfter))
        XCTAssertTrue(waitUntilDeselected(headphonesOnly))
        speakAfter.tap()
        XCTAssertTrue(waitUntilDeselected(textOnly))
        XCTAssertTrue(waitUntilSelected(speakAfter))
        XCTAssertTrue(waitUntilDeselected(headphonesOnly))
        headphonesOnly.tap()
        XCTAssertTrue(waitUntilDeselected(textOnly))
        XCTAssertTrue(waitUntilDeselected(speakAfter))
        XCTAssertTrue(waitUntilSelected(headphonesOnly))
        captureScreenshot(named: "settings-native-form-top", of: app)

        let voiceSectionY = voiceSection.frame.minY
        let closeButtonY = closeButton.frame.minY
        let dragStart = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let dragEnd = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)

        let preferenceSection = app.staticTexts["通用偏好"].firstMatch
        let autoSpeak = element("settings.autoSpeakToggle", in: app)
        let appearanceSection = app.staticTexts["外观"].firstMatch
        let systemAppearance = element("settings.appearance.system", in: app)
        XCTAssertLessThan(voiceSection.frame.minY, voiceSectionY)
        XCTAssertEqual(closeButton.frame.minY, closeButtonY, accuracy: 1)
        XCTAssertTrue(preferenceSection.waitForExistence(timeout: 2))
        XCTAssertTrue(autoSpeak.waitForExistence(timeout: 2))
        XCTAssertTrue(appearanceSection.waitForExistence(timeout: 2))
        XCTAssertTrue(systemAppearance.waitForExistence(timeout: 2))
        XCTAssertLessThan(preferenceSection.frame.minY, autoSpeak.frame.minY)
        XCTAssertLessThan(autoSpeak.frame.minY, appearanceSection.frame.minY)
        XCTAssertLessThan(appearanceSection.frame.minY, systemAppearance.frame.minY)
        XCTAssertTrue(waitUntilHittable(systemAppearance))
        captureScreenshot(named: "settings-native-form-scrolled", of: app)

        closeButton.tap()
        XCTAssertTrue(waitUntilAbsent(form))
        tabButton(named: "语音", in: app).tap()
        let playbackMenu = element("conversation-playback-menu", in: app)
        XCTAssertTrue(playbackMenu.waitForExistence(timeout: 3))
        XCTAssertEqual(playbackMenu.label, "译文朗读方式：仅戴耳机时朗读")
    }

    @MainActor
    func testAppearancePickerSelectsEveryModeAndPersistsAcrossRelaunch() throws {
        let app = launchApp(mode: "text", sheet: "settings")
        let form = element("settings.form", in: app)
        XCTAssertTrue(form.waitForExistence(timeout: 3))

        let systemAppearance = app.buttons["settings.appearance.system"].firstMatch
        let lightAppearance = app.buttons["settings.appearance.light"].firstMatch
        let darkAppearance = app.buttons["settings.appearance.dark"].firstMatch
        // 滚到最下面那一行为止：它可点了，它上面的两行必然也已实现并可点。
        XCTAssertTrue(scrollUntilHittable(darkAppearance, in: form))
        XCTAssertTrue(systemAppearance.waitForExistence(timeout: 2))
        XCTAssertTrue(lightAppearance.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilSelected(systemAppearance))
        XCTAssertTrue(waitUntilDeselected(lightAppearance))
        XCTAssertTrue(waitUntilDeselected(darkAppearance))

        lightAppearance.tap()
        XCTAssertTrue(waitUntilDeselected(systemAppearance))
        XCTAssertTrue(waitUntilSelected(lightAppearance))
        XCTAssertTrue(waitUntilDeselected(darkAppearance))
        captureScreenshot(named: "settings-appearance-light", of: app)

        systemAppearance.tap()
        XCTAssertTrue(waitUntilSelected(systemAppearance))
        XCTAssertTrue(waitUntilDeselected(lightAppearance))
        XCTAssertTrue(waitUntilDeselected(darkAppearance))

        darkAppearance.tap()
        XCTAssertTrue(waitUntilDeselected(systemAppearance))
        XCTAssertTrue(waitUntilDeselected(lightAppearance))
        XCTAssertTrue(waitUntilSelected(darkAppearance))
        captureScreenshot(named: "settings-appearance-dark", of: app)

        app.terminate()
        let relaunchedApp = launchApp(
            mode: "text",
            sheet: "settings",
            resetSettings: false
        )
        let relaunchedForm = element("settings.form", in: relaunchedApp)
        XCTAssertTrue(relaunchedForm.waitForExistence(timeout: 3))
        captureScreenshot(named: "settings-appearance-dark-relaunch", of: relaunchedApp)

        let relaunchedSystem = relaunchedApp.buttons["settings.appearance.system"].firstMatch
        let relaunchedLight = relaunchedApp.buttons["settings.appearance.light"].firstMatch
        let relaunchedDark = relaunchedApp.buttons["settings.appearance.dark"].firstMatch
        XCTAssertTrue(scrollUntilHittable(relaunchedDark, in: relaunchedForm))
        XCTAssertTrue(relaunchedSystem.waitForExistence(timeout: 2))
        XCTAssertTrue(relaunchedLight.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilDeselected(relaunchedSystem))
        XCTAssertTrue(waitUntilDeselected(relaunchedLight))
        XCTAssertTrue(waitUntilSelected(relaunchedDark))
    }

    @MainActor
    func testCameraShutterOverlaysTranslationsOnTheCapturedPhoto() throws {
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
        XCTAssertEqual(elementCount("camera.exposureButton", in: app), 0)

        let tabBarFrame = app.tabBars.firstMatch.frame
        XCTAssertFalse(gallery.frame.intersects(tabBarFrame))
        XCTAssertFalse(shutter.frame.intersects(tabBarFrame))
        XCTAssertFalse(flash.frame.intersects(tabBarFrame))
        shutter.tap()

        // 同语音处理：加载态在 XCUI 的点后空闲等待返回之前就结束了，
        // 只断言稳定的终态与数据。
        let status = element("camera.recognitionTitle", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(shutter.isEnabled)

        // 至少一块译文贴片就地叠在照片上。
        let firstBlock = element("camera.block.0", in: app)
        XCTAssertTrue(firstBlock.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(elementCount("camera.block.1", in: app), 0, "多行告示应识别出多块")
        captureScreenshot(named: "camera-overlay", of: app)

        // 贴片的 label 是原文、value 是译文：断言两者的关系而非罐头字面值——
        // 源语言中文、目标语言英文，译文必须含拉丁字母且不等于原文。
        let source = firstBlock.label
        let translated = firstBlock.value as? String ?? ""
        XCTAssertFalse(source.isEmpty)
        XCTAssertNotEqual(translated, source, "贴片仍显示原文说明译文没填进去")
        XCTAssertNotNil(
            translated.rangeOfCharacter(from: .latinLetters),
            "目标语言为英文时译文应含拉丁字母，实际：\(translated)"
        )
    }

    @MainActor
    func testTappingAnOverlayBlockOpensDetailAndSavesToHistory() throws {
        let app = launchApp(mode: "camera")

        let shutter = element("camera.shutterButton", in: app)
        XCTAssertTrue(shutter.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilHittable(shutter))
        shutter.tap()

        let firstBlock = element("camera.block.0", in: app)
        XCTAssertTrue(firstBlock.waitForExistence(timeout: 5))
        let blockSource = firstBlock.label
        XCTAssertTrue(waitUntilHittable(firstBlock))
        firstBlock.tap()

        // 详情页给出原文/译文对照。
        let detailSource = element("camera.blockDetail.source", in: app)
        let detailTranslation = element("camera.blockDetail.translation", in: app)
        XCTAssertTrue(detailSource.waitForExistence(timeout: 4))
        XCTAssertTrue(detailTranslation.waitForExistence(timeout: 4))
        XCTAssertEqual(detailSource.label, blockSource, "详情里的原文应与贴片上那块一致")
        XCTAssertNotEqual(detailTranslation.label, detailSource.label)
        captureScreenshot(named: "camera-block-detail", of: app)

        let translationText = detailTranslation.label
        let save = element("camera.blockDetail.save", in: app)
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertTrue(waitUntilHittable(save))
        save.tap()

        let copy = element("camera.blockDetail.copy", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: 2))
        copy.tap()
        XCTAssertTrue(element("camera.blockDetail.speak", in: app).exists)

        // 存进去的那条要能在历史记录里找回来。
        let closeDetail = element("camera.blockDetail.close", in: app)
        XCTAssertTrue(closeDetail.waitForExistence(timeout: 2))
        closeDetail.tap()
        XCTAssertTrue(waitUntilAbsent(detailTranslation))

        tabButton(named: "文字", in: app).tap()
        let historyButton = element("history-button", in: app)
        XCTAssertTrue(historyButton.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilHittable(historyButton))
        historyButton.tap()

        let savedEntry = firstElement(containingLabel: translationText, in: app)
        XCTAssertTrue(savedEntry.waitForExistence(timeout: 4), "相机译文没有出现在历史记录里")
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
        XCTAssertTrue(wait(for: NSPredicate(format: "label BEGINSWITH %@", "正在"), on: listeningStatus))

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
        XCTAssertTrue(wait(for: NSPredicate(format: "label == %@", "已暂停 · 轻点继续"), on: restoredListeningStatus))
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
        language: String = "zh-Hans",
        locale: String = "zh_Hans_CN",
        resetSettings: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
            "--uitest-mode", mode,
            // 固定演示译文/脚本化语音/合成拍照与识别，
            // UI 测试不碰真实网络、麦克风、TTS 与相机。
            "--uitest-canned-translation",
            "--uitest-canned-speech",
            "--uitest-canned-camera"
        ]
        if resetSettings {
            app.launchArguments.append("--uitest-reset-settings")
        }
        if let sheet {
            app.launchArguments.append(contentsOf: ["--uitest-sheet", sheet])
        }
        if reduceMotion {
            app.launchArguments.append("--uitest-reduce-motion")
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

    /// 把落在折叠线以下的行拖进可点区域，拖到就停。
    ///
    /// 为什么不用 `swipeUp()`：那是带惯性的甩动，静止位置由减速曲线决定——机器一忙，
    /// 同一个手势可能停在目标上方，也可能冲过头把目标甩出顶部，后者等多久都等不到
    /// hittable。这里每次只拖容器高度的 1/3：不足半屏，所以单次拖动不可能让目标从
    /// 折叠线以下直接跨到顶部以外；每拖一次复查一次，一旦可点立刻停。
    ///
    /// 为什么不能靠"点击前框架会自动滚动到可见"：实测不够。设置表单里的行是**惰性
    /// 实现**的——未滚动时 `settings.appearance.dark` 连 `exists` 都是 false（删掉
    /// 滚动后该测试在 674 行 `waitForExistence` 直接判负），框架的 scroll-to-visible
    /// 对还没进入元素树的行无能为力。
    ///
    /// 上限 6 次 = 两倍容器高度，覆盖设置表单四个分区的全部行程还留一倍余量。
    @MainActor
    @discardableResult
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in container: XCUIElement,
        maxDrags: Int = 6
    ) -> Bool {
        for _ in 0..<maxDrags {
            if element.exists, element.isHittable { return true }
            dragUp(in: container, byFractionOfHeight: 1.0 / 3.0)
        }
        return element.exists && element.isHittable
    }

    /// 定长拖动。起点固定在容器 dy 0.78：再往下会进入底部安全区与首页指示条的系统
    /// 边缘手势带，拖拽会被系统截走。`press` 0.05 秒是为了让触点先坐实，走 drag 而
    /// 不是 flick——少了这 0.05 秒，落点又变回由惯性决定。
    @MainActor
    private func dragUp(in container: XCUIElement, byFractionOfHeight fraction: CGFloat) {
        let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78 - fraction))
        start.press(forDuration: 0.05, thenDragTo: end)
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
        // 用原生 waitForNonExistence 而不是 "exists == NO" 谓词：两者读的都是
        // exists，其定义就是「能否在无障碍树快照里匹配到」，而结果区那种
        // .accessibilityHidden(true) 的隐藏同样把节点移出该树，所以语义逐字等价。
        // 差别在于原生实现走 XCUITest 自己的等待，不受谓词期望那套粗采样周期限制。
        element.waitForNonExistence(timeout: settleTimeout)
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
        timeout: TimeInterval = settleTimeout
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

private extension CharacterSet {
    /// 平假名 + 片假名两个 Unicode 区块。断言"译文属于哪种语言"时用它，
    /// 这样不必把某句罐头译文钉成规格，换成真实翻译服务后断言依然成立。
    static let japaneseKana = CharacterSet(charactersIn: "\u{3040}"..."\u{30FF}")
    /// 基本拉丁字母。同上，用来判定"译文确实是英文"而不钉死某一句。
    static let latinLetters = CharacterSet(charactersIn: "a"..."z")
        .union(CharacterSet(charactersIn: "A"..."Z"))
}
