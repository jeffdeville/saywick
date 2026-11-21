import XCTest
import UIKit
import VoiceKeyboardCore
@testable import LocalVoiceKeyboard

@MainActor private final class NoAccessKeyboard: KeyboardViewController {
    override var hasFullAccess: Bool { false }
}

@MainActor
final class TypingFallbackTests: XCTestCase {
    func testKeysAndModeSwitchesWithoutFullAccess() throws {
        let keyboard = NoAccessKeyboard()
        keyboard.loadViewIfNeeded()
        XCTAssertFalse(keyboard.hasFullAccess)
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 320, height: 318)
        keyboard.view.layoutIfNeeded()
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
        XCTAssertTrue(try button("space", in: keyboard.view).isEnabled)
        XCTAssertTrue(try button("return", in: keyboard.view).isEnabled)
        XCTAssertTrue(try button("⌫", in: keyboard.view).isEnabled)
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 320, height: 274)
        keyboard.view.layoutIfNeeded()
        let space = try button("space", in: keyboard.view)
        XCTAssertEqual(space.convert(space.bounds, to: keyboard.view).maxY, 268, accuracy: 1)
        let q = try button("Q", in: keyboard.view)
        let a = try button("A", in: keyboard.view)
        let z = try button("Z", in: keyboard.view)
        XCTAssertEqual(q.bounds.height, z.bounds.height, accuracy: 1)
        XCTAssertEqual(q.bounds.width, a.bounds.width, accuracy: 1)
        XCTAssertGreaterThan(a.convert(a.bounds, to: keyboard.view).minX, q.convert(q.bounds, to: keyboard.view).minX)
        let image = UIGraphicsImageRenderer(size: keyboard.view.bounds.size).image { context in
            keyboard.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Typing fallback at 320 points"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testKeyboardActionsStayInlineAndBottomRowIsAnchored() throws {
        let keyboard = NoAccessKeyboard()
        keyboard.loadViewIfNeeded()
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 393, height: 274)
        keyboard.view.layoutIfNeeded()
        let bottom = try button("return", in: keyboard.view)
        let frame = bottom.convert(bottom.bounds, to: keyboard.view)
        XCTAssertEqual(frame.maxY, 268, accuracy: 1)
        try button("More", in: keyboard.view).sendActions(for: .touchUpInside)
        XCTAssertNil(keyboard.presentedViewController)
        try button("Enable Full Access", in: keyboard.view).sendActions(for: .touchUpInside)
        XCTAssertNil(keyboard.presentedViewController)
        try button("More", in: keyboard.view).sendActions(for: .touchUpInside)
        keyboard.view.layoutIfNeeded()

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

    func testSecondSymbolPageAndDarkAppearance() throws {
        let keyboard = NoAccessKeyboard()
        keyboard.loadViewIfNeeded()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = keyboard
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try button("123", in: keyboard.view).sendActions(for: .touchUpInside)
        try button("#+=", in: keyboard.view).sendActions(for: .touchUpInside)
        XCTAssertTrue(try button("€", in: keyboard.view).isEnabled)
        try button("123", in: keyboard.view).sendActions(for: .touchUpInside)
        XCTAssertTrue(try button("1", in: keyboard.view).isEnabled)
        try button("ABC", in: keyboard.view).sendActions(for: .touchUpInside)
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 393, height: 274)
        keyboard.view.layoutIfNeeded()
        let q = try button("q", in: keyboard.view)
        XCTAssertEqual(q.traitCollection.userInterfaceStyle, .dark)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertNotEqual(q.configuration?.background.backgroundColor?.resolvedColor(with: dark), UIColor.white)
        let image = UIGraphicsImageRenderer(size: keyboard.view.bounds.size).image { _ in
            keyboard.view.layer.render(in: UIGraphicsGetCurrentContext()!)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Typing keyboard dark at 393 points"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFirstLoadShowsLettersAndToolbarAndReappearanceResetsSymbols() throws {
        let keyboard = NoAccessKeyboard(); keyboard.loadViewIfNeeded()
        func visible(_ view: UIView) -> Bool { !view.isHidden && (view.superview.map(visible) ?? true) }
        for title in ["q", "w", "e", "Polish", "More", "Undo insertion", "Enable Full Access"] {
            XCTAssertTrue(visible(try button(title, in: keyboard.view)), title)
        }
        try button("123", in: keyboard.view).sendActions(for: .touchUpInside)
        XCTAssertTrue(visible(try button("1", in: keyboard.view)))
        keyboard.viewWillAppear(false)
        XCTAssertTrue(visible(try button("q", in: keyboard.view)))
        keyboard.viewDidDisappear(false)
    }

    func testExistingEnginePreferenceMigratesWithoutChangingCleanup() {
        let suite = "SaywickMigrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("maiVoiceLive", forKey: "selectedEngine")
        defaults.set("none", forKey: "selectedPostProcessor")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(defaults: defaults, history: HistoryModel(defaults: defaults, root: root))
        XCTAssertEqual(model.selectedEngineID, .parakeetStreaming)
        XCTAssertEqual(model.selectedPostProcessorID, .none)
        XCTAssertEqual(defaults.string(forKey: "selectedEngine"), "parakeetStreaming")
    }

    func testOnDeviceCleanupRestoredOnceAndExplicitOffSurvivesRelaunch() {
        let suite = "CleanupMigration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set("none", forKey: "selectedPostProcessor")
        defaults.set(true, forKey: "cleanupOptInMigrationV1")
        var dependencies = DictationController.Dependencies()
        dependencies.activities = false
        let first = AppModel(defaults: defaults, history: HistoryModel(defaults: defaults, root: root), dependencies: dependencies)
        XCTAssertEqual(first.selectedPostProcessorID, .foundationModels)
        first.selectedPostProcessorID = .none
        let relaunched = AppModel(defaults: defaults, history: HistoryModel(defaults: defaults, root: root), dependencies: dependencies)
        XCTAssertEqual(relaunched.selectedPostProcessorID, .none)
        defaults.removeObject(forKey: "selectedPostProcessor")
        let fresh = AppModel(defaults: defaults, history: HistoryModel(defaults: defaults, root: root), dependencies: dependencies)
        XCTAssertEqual(fresh.selectedPostProcessorID, .foundationModels)
    }

    private func button(_ title: String, in view: UIView) throws -> UIButton {
        func matches(_ v: UIView) -> [UIButton] {
            let own = (v as? UIButton).map { button in
                button.configuration?.title == title || button.accessibilityLabel == title ? [button] : []
            } ?? []
            return own + v.subviews.flatMap(matches)
        }
        func visible(_ v: UIView) -> Bool { !v.isHidden && (v.superview.map(visible) ?? true) }
        let candidates = matches(view)
        if let button = candidates.first(where: { visible($0) }) ?? candidates.first { return button }
        throw NSError(domain: "Missing button: " + title, code: 1)
    }
}
