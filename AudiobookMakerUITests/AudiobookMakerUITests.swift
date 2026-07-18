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
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
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
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))

        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.buttons["继续"].waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))

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
    func testEPUBToM4BToZIPEndToEndWithDeterministicRuntime() throws {
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
        primaryAction.click()
        XCTAssertTrue(app.buttons["导出有声书…"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["2 / 2 已完成"].waitForExistence(timeout: 5))

        app.buttons["导出有声书…"].click()
        XCTAssertTrue(app.descendants(matching: .any)["export.completed"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["导出完成：端到端测试有声书.zip"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func menuExists(in app: XCUIApplication, labels: [String]) -> Bool {
        labels.contains { app.menuBars.menuBarItems[$0].exists }
    }
}
