import Foundation
import Observation
import OSLog
import VoiceKeyboardCore

/// Fixed labels only: no URLs, transcript contents, or credentials.
@MainActor
@Observable
final class ActivationDiagnostics {
    struct Event: Codable, Identifiable {
        let id: UUID
        let date: Date
        let label: String
    }
    static let shared = ActivationDiagnostics()
    private(set) var events: [Event]
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.saywick.app", category: "Activation")
    private let storageKey = "activationEventsV1"
    private init() {
        events = Array((defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([Event].self, from: $0)
        } ?? []).suffix(40))
    }
    func record(_ label: String) {
        events.append(Event(id: UUID(), date: Date(), label: label))
        events = Array(events.suffix(40))
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: storageKey) }
        logger.info("\(label, privacy: .public)")
    }
}

@MainActor
enum ShortcutRequests {
    private static let key = "pendingShortcutRequestV1"
    static func enqueue(_ action: AppLaunchRequest.Action) {
        UserDefaults.standard.set(try? JSONEncoder().encode(AppLaunchRequest(action: action)), forKey: key)
        ActivationDiagnostics.shared.record(action == .start ? "Start shortcut invoked" : "History shortcut invoked")
    }
    static func consume(from defaults: UserDefaults) -> AppLaunchRequest.Action? {
        // Legacy flags have no timestamp and cannot establish a fresh request.
        for legacyKey in ["saywickPendingStart", "saywickPendingHistory"] where defaults.object(forKey: legacyKey) != nil {
            defaults.removeObject(forKey: legacyKey)
        }
        guard let data = defaults.data(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        guard let request = try? JSONDecoder().decode(AppLaunchRequest.self, from: data), request.isFresh() else {
            ActivationDiagnostics.shared.record("Expired or invalid shortcut request discarded")
            return nil
        }
        return request.action
    }
}
