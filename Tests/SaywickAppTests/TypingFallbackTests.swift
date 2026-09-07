import XCTest
import UIKit
import VoiceKeyboardCore
@testable import LocalVoiceKeyboard

@MainActor
final class TypingFallbackTests: XCTestCase {
    func testKeysAndModeSwitchesWithoutFullAccess() throws {
        let keyboard = KeyboardViewController()
        keyboard.loadViewIfNeeded()
        XCTAssertFalse(keyboard.hasFullAccess)
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 320, height: 318)
        keyboard.view.layoutIfNeeded()
        try button("ABC", in: keyboard.view).sendActions(for: .touchUpInside)
        for character in "abcdefghijklmnopqrstuvwxyz" {
            XCTAssertTrue(try button(String(character), in: keyboard.view).isEnabled)
        }
        try button("⇧", in: keyboard.view).sendActions(for: .touchUpInside)
        XCTAssertNotNil(try button("A", in: keyboard.view))
        try button("123", in: keyboard.view).sendActions(for: .touchUpInside)
        for character in "0123456789.,?!'" {
            XCTAssertTrue(try button(String(character), in: keyboard.view).isEnabled)
        }
        try button("ABC", in: keyboard.view).sendActions(for: .touchUpInside)
        try button("Voice", in: keyboard.view).sendActions(for: .touchUpInside)
        try button("ABC", in: keyboard.view).sendActions(for: .touchUpInside)
        XCTAssertTrue(try button("space", in: keyboard.view).isEnabled)
        XCTAssertTrue(try button("return", in: keyboard.view).isEnabled)
        XCTAssertTrue(try button("⌫", in: keyboard.view).isEnabled)
        let image = UIGraphicsImageRenderer(size: keyboard.view.bounds.size).image { context in
            keyboard.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Typing fallback at 320 points"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testKeyboardActionsStayInlineAndBottomRowIsAnchored() async throws {
        let keyboard = KeyboardViewController()
        keyboard.loadViewIfNeeded()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 250))
        window.rootViewController = keyboard
        window.isHidden = false
        defer { window.isHidden = true }
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 393, height: 250)
        keyboard.view.layoutIfNeeded()
        let bottom = try button("return", in: keyboard.view)
        let frame = bottom.convert(bottom.bounds, to: keyboard.view)
        XCTAssertEqual(frame.maxY, 244, accuracy: 1)
        try button("More", in: keyboard.view).sendActions(for: .touchUpInside)
        XCTAssertNil(keyboard.presentedViewController)
        try button("Enable Full Access", in: keyboard.view).sendActions(for: .touchUpInside)
        XCTAssertNil(keyboard.presentedViewController)
        try button("More", in: keyboard.view).sendActions(for: .touchUpInside)
        keyboard.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(size: keyboard.view.bounds.size).image { context in
            UIColor.systemGray5.setFill()
            context.fill(keyboard.view.bounds)
            keyboard.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Compact dictation keyboard"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testExistingEnginePreferenceMigratesWithoutChangingCleanup() {
        let suite = "SaywickMigrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("maiVoiceLive", forKey: "selectedEngine")
        defaults.set("none", forKey: "selectedPostProcessor")
        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.selectedEngineID, .parakeetStreaming)
        XCTAssertEqual(model.selectedPostProcessorID, .none)
        XCTAssertEqual(defaults.string(forKey: "selectedEngine"), "parakeetStreaming")
    }

    private func button(_ title: String, in view: UIView) throws -> UIButton {
        if let button = view as? UIButton, button.configuration?.title == title { return button }
        for child in view.subviews {
            if let button = try? button(title, in: child) { return button }
        }
        throw NSError(domain: "Missing button: " + title, code: 1)
    }
}
