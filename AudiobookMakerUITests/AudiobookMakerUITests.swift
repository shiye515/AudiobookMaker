import XCTest

final class AudiobookMakerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testApplicationLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["书籍"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["导入 EPUB"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(menuExists(in: app, labels: ["Book", "书籍"]))
        XCTAssertTrue(menuExists(in: app, labels: ["File", "文件"]))
        XCTAssertTrue(menuExists(in: app, labels: ["View", "显示"]))
    }

    @MainActor
    func testEnglishLocalizationLaunchesWithoutClippedPrimaryNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Books"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import EPUB"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(menuExists(in: app, labels: ["Book"]))
        XCTAssertTrue(menuExists(in: app, labels: ["File"]))
        XCTAssertTrue(menuExists(in: app, labels: ["View"]))
    }

    @MainActor
    func testEnglishPopulatedLibraryShowsLocalizedCountsStatusesAndActions() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "--uitest-populated-library",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let localizedBookRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "24 chapters", "Converting")
        ).firstMatch
        XCTAssertTrue(localizedBookRow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["10 / 24 completed"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPopulatedLibraryExposesAccessibleCoreControlsAndStatusValues() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "--uitest-populated-library",
            "--uitest-short-window",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        let importButton = app.buttons["toolbar.import"]
        let primaryAction = app.buttons["book.primaryAction"]
        let moreActions = app.descendants(matching: .any)["book.moreActions"]
        let queueButton = app.descendants(matching: .any)["queue.open"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))
        XCTAssertTrue(moreActions.waitForExistence(timeout: 5))
        XCTAssertTrue(queueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(importButton.label.isEmpty)
        XCTAssertFalse(primaryAction.label.isEmpty)
        XCTAssertFalse(moreActions.label.isEmpty)
        XCTAssertFalse(queueButton.label.isEmpty)

        let queueSummary = app.descendants(matching: .any)["queue.summary"]
        XCTAssertTrue(queueSummary.waitForExistence(timeout: 5))
        XCTAssertFalse(queueSummary.label.isEmpty)
        XCTAssertFalse(String(describing: queueSummary.value ?? "").isEmpty)

        let localProcessingTitle = app.staticTexts["全部在本机处理"]
        let localProcessingDetail = app.staticTexts["书籍内容不会上传"]
        XCTAssertTrue(localProcessingTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(localProcessingDetail.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(localProcessingDetail.frame.maxY, queueSummary.frame.minY - 2)

        let chapterStatus = app.descendants(matching: .any)["chapter.status.1"]
        XCTAssertTrue(chapterStatus.waitForExistence(timeout: 5))
        XCTAssertFalse(chapterStatus.label.isEmpty)
        XCTAssertFalse(String(describing: chapterStatus.value ?? "").isEmpty)
    }

    @MainActor
    func testKeyboardShortcutsControlCoreFlow() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "--uitest-populated-library",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.click()

        app.typeKey(".", modifierFlags: .command)
        let primary = app.buttons["book.primaryAction"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertEqual(primary.label, "继续")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertEqual(primary.label, "暂停")

        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.buttons["删除 App 管理的数据"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("漫长")
        XCTAssertTrue(app.staticTexts["漫长的旅程"].firstMatch.waitForExistence(timeout: 5))

        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["转换"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["最大并发任务"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testModelMenuDownloadStateAndVoicePreviewFailureAreAccessible() throws {
        let notInstalled = XCUIApplication()
        notInstalled.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "--uitest-model-not-installed",
            "--uitest-fixed-window",
        ]
        notInstalled.launch()
        XCTAssertTrue(notInstalled.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(menuExists(in: notInstalled, labels: ["Model", "模型"]))
        selectKokoroFromMenu(in: notInstalled)
        let notInstalledKokoro = notInstalled.descendants(matching: .any)["model.row.\(TTSModelCatalogTestID.kokoro)"]
        XCTAssertTrue(notInstalledKokoro.waitForExistence(timeout: 5))
        XCTAssertTrue(notInstalled.buttons["model.download"].waitForExistence(timeout: 5))
        XCTAssertFalse(notInstalled.buttons["model.download"].label.isEmpty)
        notInstalled.terminate()

        let ready = XCUIApplication()
        ready.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "--uitest-kokoro-ready",
            "--uitest-fixed-window",
        ]
        ready.launch()
        XCTAssertTrue(ready.windows.firstMatch.waitForExistence(timeout: 5))
        selectKokoroFromMenu(in: ready)
        let readyKokoro = ready.descendants(matching: .any)["model.row.\(TTSModelCatalogTestID.kokoro)"]
        XCTAssertTrue(readyKokoro.waitForExistence(timeout: 5))
        let voicePicker = ready.popUpButtons["voice.picker"]
        XCTAssertTrue(voicePicker.waitForExistence(timeout: 5))
        voicePicker.click()
        let alternateVoice = ready.menuItems["中文女声 · zf_002"]
        XCTAssertTrue(alternateVoice.waitForExistence(timeout: 5))
        alternateVoice.click()
        XCTAssertFalse(ready.staticTexts["所选音色不属于当前模型版本。"].exists)
        let search = ready.textFields["voice.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("zf_002")
        XCTAssertTrue(ready.buttons["voice.preview"].exists)
        XCTAssertFalse(ready.buttons["voice.preview"].label.isEmpty)
        ready.buttons["voice.preview"].click()
        XCTAssertTrue(ready.descendants(matching: .any)["voice.preview.error"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testDarkAccessibleAppearanceAndNarrowWindowRemainUsable() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-AppleInterfaceStyle", "Dark",
            "-NSIncreaseContrast", "YES",
            "-NSReduceTransparency", "YES",
            "-NSReduceMotion", "YES",
            "--uitest-populated-library",
            "--uitest-narrow-window",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "window layout settles")], timeout: 0.5)
        XCTAssertLessThanOrEqual(window.frame.width, 800)
        XCTAssertTrue(app.buttons["toolbar.import"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["book.primaryAction"].exists
                || app.staticTexts["书籍"].firstMatch.exists
        )
        let queueButton = app.descendants(matching: .any)["queue.open"]
        XCTAssertTrue(queueButton.waitForExistence(timeout: 5))
        XCTAssertEqual(queueButton.label, "查看队列")
        XCTAssertLessThanOrEqual(queueButton.frame.maxX, window.frame.maxX - 16)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Dark-IncreaseContrast-ReduceTransparency-ReduceMotion-Narrow"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testEPUBToSingleM4BEndToEndWithDeterministicRuntime() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "--uitest-e2e",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["端到端测试图书"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["第一章"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["第二章"].firstMatch.waitForExistence(timeout: 5))

        let primaryAction = app.buttons["book.primaryAction"]
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))
        XCTAssertEqual(primaryAction.label, "开始转换")
        XCTAssertTrue(primaryAction.isHittable)
        // The final reloadBooks() call can replace the SwiftUI button between
        // XCUI's lookup and click. Capture its on-screen coordinate after the
        // accessibility assertions so the click survives that view refresh.
        primaryAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.buttons["导出有声书…"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["2 / 2 已完成"].waitForExistence(timeout: 5))

        app.buttons["导出有声书…"].click()
        let completion = app.descendants(matching: .any)["export.completed"]
        XCTAssertTrue(completion.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["导出完成：端到端测试有声书.m4b"].waitForExistence(timeout: 5))
        XCTAssertTrue(completion.waitForNonExistence(timeout: 8))
    }

    @MainActor
    private func menuExists(in app: XCUIApplication, labels: [String]) -> Bool {
        labels.contains { app.menuBars.menuBarItems[$0].exists }
    }

    @MainActor
    private func selectKokoroFromMenu(in app: XCUIApplication) {
        let englishModelMenu = app.menuBars.menuBarItems["Model"]
        let modelMenu = englishModelMenu.exists ? englishModelMenu : app.menuBars.menuBarItems["模型"]
        XCTAssertTrue(modelMenu.waitForExistence(timeout: 5))
        modelMenu.click()
        let kokoro = app.menuItems["Kokoro 多语言 Int8"]
        XCTAssertTrue(kokoro.waitForExistence(timeout: 5))
        kokoro.click()
    }
}

private enum TTSModelCatalogTestID {
    static let kokoro = "sherpa-onnx/kokoro-multi-lang-v1_1-int8"
}
