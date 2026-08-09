//
//  StikDebugUITestsLaunchTests.swift
//  StikDebugUITests
//
//  Created by Stephen on 3/26/25.
//

import XCTest

final class StikDebugUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Pikmin Helper Launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
