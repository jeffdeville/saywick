@preconcurrency import ActivityKit
import Foundation

@MainActor
final class RecordingActivity {
    private var activity: Activity<SaywickActivityAttributes>?
    func removeOrphanedActivities() async {
        let orphaned = Activity<SaywickActivityAttributes>.activities.filter { $0.id != activity?.id }
        for old in orphaned { await old.end(nil, dismissalPolicy: .immediate) }
        if !orphaned.isEmpty { ActivationDiagnostics.shared.record("Removed stale recording Live Activities") }
    }
    func start(engine: String, phase: String = "Recording", required: Bool = false) throws {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if required { throw SpeechEngineError.unavailable("Enable Live Activities for Saywick in Settings to record from the background.") }
            return
        }
        do {
            activity = try Activity.request(attributes: SaywickActivityAttributes(startedAt: Date(), engine: engine),
                content: ActivityContent(state: .init(phase: phase), staleDate: nil))
        } catch {
            if required { throw SpeechEngineError.unavailable("Could not start the recording indicator. Enable Live Activities for Saywick and try again. \(error.localizedDescription)") }
        }
    }
    func update(phase: String) async {
        await activity?.update(ActivityContent(state: .init(phase: phase), staleDate: nil))
    }
    func finish() async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(ActivityContent(state: .init(phase: "Check History"), staleDate: nil), dismissalPolicy: .immediate)
    }
}
