import XCTest

@MainActor
final class LocalVoiceKeyboardUITests: XCTestCase {
    func testSimulatorDemoStreamsFinalizesAndCleansTranscript() throws {
        try verifyDemo(engine: "maiTranscribe2")
    }

    func testMAILiveDemoStreamsAndFinalizesWithoutCleanup() throws {
        try verifyDemo(engine: "maiVoiceLive")
    }

    func testCustomWordsApplyToFinalMicrosoftTranscript() throws {
        try verifyDemo(engine: "maiVoiceLive", customWords: "local voice simulator = Breccan")
    }

    func testHistorySurvivesClearAndRestoresOriginal() throws {
        try verifyDemo(engine: "maiVoiceLive")
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

        let stopButton = app.buttons["Stop and transcribe"]
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
