import AppIntents
import Foundation

struct StartSaywickDictation: AppIntent {
    static let title: LocalizedStringResource = "Start Saywick dictation"
    static let description = IntentDescription("Open Saywick and start the selected speech engine. Cloud engines send audio to your configured provider.")
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "saywickPendingStart")
        return .result()
    }
}
struct OpenSaywickHistory: AppIntent {
    static let title: LocalizedStringResource = "Open Saywick history"
    static var openAppWhenRun: Bool { true }
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "saywickPendingHistory")
        return .result()
    }
}
struct SaywickShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartSaywickDictation(), phrases: ["Start \(.applicationName) dictation"], shortTitle: "Start dictation", systemImageName: "mic")
        AppShortcut(intent: OpenSaywickHistory(), phrases: ["Open \(.applicationName) history"], shortTitle: "History", systemImageName: "clock.arrow.circlepath")
    }
}
