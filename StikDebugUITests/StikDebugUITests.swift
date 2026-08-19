import XCTest

final class PikminHelperUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMainNavigationIsVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-testing-skip-setup",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"
        ]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["路线"].exists)
        XCTAssertTrue(app.tabBars.buttons["记录"].exists)
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)
        XCTAssertTrue(app.staticTexts["Pikmin Helper"].exists)
    }

    @MainActor
    func testMovementModesShareOneMapEntryPoint() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-testing-skip-setup",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"
        ]
        app.launch()

        let routeTab = app.tabBars.buttons["路线"]
        XCTAssertTrue(routeTab.waitForExistence(timeout: 5))
        routeTab.tap()

        XCTAssertTrue(app.navigationBars["模拟位置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["定点"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["摇杆"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["路线"].exists)
        XCTAssertTrue(app.textFields["搜索地点或输入经纬度"].exists)
    }
}
