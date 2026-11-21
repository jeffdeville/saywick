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
        XCTAssertTrue(app.buttons["Copy final"].exists)
        app.buttons["Original"].tap()
        XCTAssertFalse(app.buttons["Copy final"].exists)
        let restore = app.buttons["Use original in keyboard"].firstMatch
        for _ in 0..<6 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        let copy = app.buttons["Copy original"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2))
        restore.tap()
        XCTAssertTrue(app.staticTexts["Restored from History — ready to insert"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["transcriptText"].label.contains("local voice simulator"))
    }

    func testTextCleanupHasNoDuplicateTemplatesLink() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Templates"].exists)
        app.buttons["Text cleanup"].tap()
        XCTAssertFalse(app.buttons["Templates"].exists)
    }

    func testSettingsOpensTemplateModelChoice() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons["Templates"].tap()
        app.buttons["New template"].tap()
        app.buttons.containing(.staticText, identifier: "Cleanup model").firstMatch.tap()
        XCTAssertTrue(app.textFields["Exact OpenAI model ID"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["stopDictation"].exists)
    }

    func testMeetingModeIsRemoved() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["startDictation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Record meeting"].exists)
    }

    private func verifyDemo(engine: String, customWords: String = "") throws {
        let app = XCUIApplication()
        app.launchEnvironment["LOCAL_VOICE_SIMULATOR_DEMO"] = "1"
        app.launchArguments = ["-selectedEngine", engine, "-selectedPostProcessor", "none", "-customWords", customWords, "-customWordsEnabled", "YES"]
        app.launch()

        let startButton = app.buttons["startDictation"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        startButton.tap()

        XCTAssertTrue(app.buttons["stopDictation"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["transcriptText"].waitForExistence(timeout: 5)
        )

        let stopButton = app.buttons["stopDictation"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        stopButton.tap()

        XCTAssertTrue(app.staticTexts["Just dictated"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Copy text"].exists)
        let cleanedTranscript = app.staticTexts["transcriptText"]
        XCTAssertTrue(cleanedTranscript.exists)
        XCTAssertTrue(
            cleanedTranscript.label.localizedCaseInsensitiveContains(customWords.isEmpty ? "local voice simulator" : "Breccan")
        )
    }
}
