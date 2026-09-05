@preconcurrency import ActivityKit
import Foundation

@MainActor
final class RecordingActivity {
    private var activity: Activity<SaywickActivityAttributes>?
    func start(engine: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: SaywickActivityAttributes(startedAt: Date(), engine: engine),
            content: ActivityContent(state: .init(phase: "Recording"), staleDate: Date().addingTimeInterval(1500)))
    }
    func finish() async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(ActivityContent(state: .init(phase: "Check History"), staleDate: nil), dismissalPolicy: .immediate)
    }
}
