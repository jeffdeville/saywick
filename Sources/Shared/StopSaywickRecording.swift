import AppIntents

struct StopSaywickRecording: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Saywick recording"
    static let description = IntentDescription("Stop recording, turn off the microphone, and save the result in History.")
    static var supportedModes: IntentModes { .background }
    @MainActor func perform() async throws -> some IntentResult {
        #if SAYWICK_APP
        try await AppModel.shared.stopFromShortcut()
        #endif
        return .result()
    }
}
