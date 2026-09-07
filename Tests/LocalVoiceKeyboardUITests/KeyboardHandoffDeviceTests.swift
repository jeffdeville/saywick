import XCTest

@MainActor
final class KeyboardHandoffDeviceTests: XCTestCase {
    func testOpenSaywickFromSettingsKeyboard() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires Saywick keyboard enabled on the phone")
        #else
        let app = XCUIApplication()
        app.terminate()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        if settings.buttons["Search"].firstMatch.exists { settings.buttons["Search"].firstMatch.tap() }
        let search = settings.searchFields.firstMatch
        guard search.waitForExistence(timeout: 5) else {
            XCTFail("Settings search unavailable; no handoff attempted")
            return
        }
        search.tap()
        let open = settings.buttons["openSaywick"]
        guard open.waitForExistence(timeout: 5) else {
            XCTFail("Saywick is not the active keyboard in Settings")
            return
        }
        settings.buttons["More"].tap()
        XCTAssertTrue(open.exists, "More must remain inline without dismissing the keyboard")
        settings.buttons["More"].tap()
        defer { app.terminate() }
        open.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let stop = app.buttons["Stop and clean up"]
        // Always release capture after checking the URL handoff.
        if app.buttons["End microphone session"].waitForExistence(timeout: 15) {
            app.buttons["End microphone session"].tap()
        } else if stop.exists { stop.tap() }
        #endif
    }
}
