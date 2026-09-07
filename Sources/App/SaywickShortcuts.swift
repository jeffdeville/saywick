import AppIntents
import Foundation

struct StartSaywickDictation: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Saywick dictation"
    static let description = IntentDescription("Start on-device dictation. Saywick opens to activate an inactive microphone; subsequent dictations can start in the background while ready.")
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    @MainActor func perform() async throws -> some IntentResult {
        if !AppModel.shared.canStartDictationInBackground {
            try await continueInForeground(alwaysConfirm: false)
        }
        try await AppModel.shared.startFromShortcut(kind: .dictation)
        return .result()
    }
}

struct StartSaywickMeeting: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Start Saywick meeting"
    static let description = IntentDescription("Record meeting audio in the background, up to four hours. Audio is saved locally; transcribe with Parakeet afterward in History.")
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    @MainActor func perform() async throws -> some IntentResult {
        try await continueInForeground(alwaysConfirm: false)
        try await AppModel.shared.startFromShortcut(kind: .meeting)
        return .result()
    }
}

struct OpenSaywickHistory: AppIntent {
    static let title: LocalizedStringResource = "Open Saywick history"
    static var supportedModes: IntentModes { .foreground }
    @MainActor func perform() async throws -> some IntentResult {
        await AppModel.shared.startServices()
        AppModel.shared.selectedTab = 1
        return .result()
    }
}

struct SaywickShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartSaywickDictation(), phrases: ["Start \(.applicationName) dictation"], shortTitle: "Start dictation", systemImageName: "mic")
        AppShortcut(intent: StartSaywickMeeting(), phrases: ["Start \(.applicationName) meeting"], shortTitle: "Record meeting", systemImageName: "person.2.wave.2")
        AppShortcut(intent: StopSaywickRecording(), phrases: ["Stop \(.applicationName) recording"], shortTitle: "Stop recording", systemImageName: "stop.circle")
        AppShortcut(intent: OpenSaywickHistory(), phrases: ["Open \(.applicationName) history"], shortTitle: "History", systemImageName: "clock.arrow.circlepath")
    }
}
