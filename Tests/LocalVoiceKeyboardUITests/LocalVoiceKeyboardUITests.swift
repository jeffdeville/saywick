import XCTest

@MainActor
final class LocalVoiceKeyboardUITests: XCTestCase {
    func testSimulatorDemoStreamsFinalizesAndCleansTranscript() throws {
        try verifyDemo(engine: "parakeetStreaming")
    }

    func testLegacyEnginePreferenceMigratesToParakeet() throws {
        try verifyDemo(engine: "maiVoiceLive")
    }

    func testCustomWordsApplyToFinalParakeetTranscript() throws {
        try verifyDemo(engine: "parakeetStreaming", customWords: "local voice simulator = Breccan")
    }

    func testHistorySurvivesClearAndRestoresOriginal() throws {
        try verifyDemo(engine: "parakeetStreaming")
        let app = XCUIApplication()
        app.buttons["Clear"].tap()
        app.tabBars.buttons["History"].tap()
        let recording = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "hello from the local voice simulator")).firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 5))
        recording.tap()
        let restore = app.buttons["Use original in keyboard"].firstMatch
        for _ in 0..<6 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()
        XCTAssertTrue(app.staticTexts["Restored from History — ready to insert"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["transcriptText"].label.contains("local voice simulator"))
    }

    func testMeetingSavesWithoutCleanupAndIgnoresClear() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LOCAL_VOICE_SIMULATOR_DEMO"] = "1"
        app.launchArguments = ["-selectedPostProcessor", "none", "-customWords", "", "-keepAudio", "NO"]
        app.launch()
        let meeting = app.buttons["Record meeting"]
        XCTAssertTrue(meeting.waitForExistence(timeout: 5))
        meeting.tap()
        let stop = app.buttons["Stop meeting"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Clear"].isEnabled)
        XCTAssertFalse(app.buttons["Restart transcript"].exists)
        stop.tap()
        XCTAssertTrue(app.staticTexts["Meeting saved — transcribe it in History"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Meeting")).firstMatch.waitForExistence(timeout: 5))
    }

    private func verifyDemo(engine: String, customWords: String = "") throws {
        let app = XCUIApplication()
        app.launchEnvironment["LOCAL_VOICE_SIMULATOR_DEMO"] = "1"
        app.launchArguments = ["-selectedEngine", engine, "-selectedPostProcessor", "none", "-customWords", customWords, "-customWordsEnabled", "YES"]
        app.launch()

        let startButton = app.buttons["Start listening"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.tap()

        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "hello from the local voice simulator this transcript stayed on device"
            ].waitForExistence(timeout: 5)
        )

        let stopButton = app.buttons["Stop and clean up"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        stopButton.tap()

        XCTAssertTrue(app.staticTexts["Ready to insert"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Copy text"].exists)
        let cleanedTranscript = app.staticTexts["transcriptText"]
        XCTAssertTrue(cleanedTranscript.exists)
        XCTAssertTrue(
            cleanedTranscript.label.localizedCaseInsensitiveContains(customWords.isEmpty ? "local voice simulator" : "Breccan")
        )
    }
}
