import XCTest

/// Physical-phone checks record a brief local clip and leave it in History.
@MainActor
final class BackgroundRecordingDeviceTests: XCTestCase {
    func testMeetingShortcutActivatesThenRecordsInBackground() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Background microphone activation requires a physical phone")
        #else
        let app = XCUIApplication()
        app.terminate()
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()
        if shortcuts.alerts.buttons["OK"].exists { shortcuts.alerts.buttons["OK"].tap() }
        if !shortcuts.navigationBars["Saywick"].exists {
            if shortcuts.buttons["BackButton"].exists { shortcuts.buttons["BackButton"].tap() }
            for _ in 0..<12 where !shortcuts.buttons["Saywick"].isHittable { shortcuts.swipeUp() }
            shortcuts.buttons["Saywick"].tap()
        }
        shortcuts.buttons["person.2.wave.2"].tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "Cold activation opens Saywick")
        finishBackgroundMeeting(in: app)
        #endif
    }

    func testMeetingContinuesAfterLeavingApp() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical microphone")
        #else
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["Record meeting"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        finishBackgroundMeeting(in: app)
        #endif
    }

    private func finishBackgroundMeeting(in app: XCUIApplication) {
        let stop = app.buttons["Stop meeting"]
        guard stop.waitForExistence(timeout: 15) else {
            XCTFail("Meeting microphone did not start")
            return
        }
        defer {
            app.activate()
            if stop.exists { stop.tap() }
        }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        sleep(5)
        app.activate()
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertTrue(app.staticTexts["Meeting saved — transcribe it in History"].waitForExistence(timeout: 10))
    }
}
