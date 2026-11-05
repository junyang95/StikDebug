import XCTest

final class PikminHelperUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMainNavigationIsVisible() throws {
        let app = launchApp()

        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["路线"].exists)
        XCTAssertTrue(app.tabBars.buttons["记录"].exists)
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)
        XCTAssertTrue(app.staticTexts["Pikmin 日常助手"].exists)
        XCTAssertTrue(app.buttons["begin-device-setup"].exists)
        XCTAssertFalse(app.staticTexts["先验证 VIP"].exists)
        XCTAssertFalse(app.buttons["close-vip-setup"].exists)
        XCTAssertFalse(app.buttons["取消验证"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["正在验证授权…"].exists)
    }

    @MainActor
    func testVIPIsTheFirstStepAfterStartingSetup() throws {
        let app = launchApp()
        let startButton = app.buttons["begin-device-setup"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.tap()

        XCTAssertTrue(app.staticTexts["先验证 VIP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["close-vip-setup"].exists)
        XCTAssertTrue(app.buttons["验证 VIP"].exists)
        XCTAssertFalse(app.buttons["请求 VPN 配置权限"].exists)
        XCTAssertFalse(app.buttons["请求 HealthKit 步数权限"].exists)
    }

    @MainActor
    func testClosingVIPSetupReturnsToBrowsableHome() throws {
        let app = launchApp()
        let startButton = app.buttons["begin-device-setup"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.tap()

        let closeButton = app.buttons["close-vip-setup"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["先验证 VIP"]
        )
        wait(for: [dismissed], timeout: 5)

        XCTAssertTrue(app.staticTexts["Pikmin 日常助手"].exists)
        XCTAssertTrue(startButton.isHittable)
        XCTAssertFalse(app.buttons["取消验证"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["正在验证授权…"].exists)
        app.tabBars.buttons["路线"].tap()
        XCTAssertTrue(app.navigationBars["模拟位置"].waitForExistence(timeout: 5))
        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(app.staticTexts["Pikmin 日常助手"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMovementModesShareOneMapEntryPoint() throws {
        let app = launchApp()

        let routeTab = app.tabBars.buttons["路线"]
        XCTAssertTrue(routeTab.waitForExistence(timeout: 5))
        routeTab.tap()

        XCTAssertTrue(app.navigationBars["模拟位置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["定点"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["摇杆"].exists)
        XCTAssertTrue(app.segmentedControls.buttons["路线"].exists)
        XCTAssertTrue(app.textFields["搜索地点或输入经纬度"].exists)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"
        ]
        app.launch()
        return app
    }
}
