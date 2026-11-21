import Foundation

/// The primary action is derived on every poll, including expiry without a new revision.
public enum KeyboardRecordingState: Equatable, Sendable {
    case needsAccess, activationNeeded, ready, starting, recording, finishing, meeting
    public static func resolve(_ snapshot: SharedSessionSnapshot?, fullAccess: Bool, now: Date = Date()) -> Self {
        guard fullAccess else { return .needsAccess }
        guard let snapshot, abs(now.timeIntervalSince(snapshot.updatedAt)) < 5 else { return .activationNeeded }
        if let session = snapshot.dictation {
            switch session.pending {
            case .activating, .starting: return .starting
            case .cancelling, .deactivating: return .finishing
            case nil: break
            }
            switch session.state {
            case .inactive: return .activationNeeded
            case .activated: return snapshot.isKeyboardSessionActive(at: now) ? .ready : .activationNeeded
            case .transcribing: return snapshot.isMeeting == true ? .meeting : .recording
            case .postProcess: return .finishing
            }
        }
        switch snapshot.phase {
        case .preparing: return .starting
        case .finalizing: return .finishing
        case .listening: return snapshot.isMeeting == true ? .meeting : .recording
        case .idle, .ready: return snapshot.isKeyboardSessionActive(at: now) ? .ready : .activationNeeded
        case .failed: return .activationNeeded
        }
    }
    public var title: String {
        switch self {
        case .needsAccess: "Enable Full Access"
        case .activationNeeded: "Activation needed"
        case .ready: "Dictate"
        case .starting: "Starting…"
        case .recording: "Stop & Insert"
        case .finishing: "Finishing…"
        case .meeting: "Stop meeting"
        }
    }
    public var command: VoiceCommandKind? {
        switch self {
        case .ready: .start
        case .recording: .stopAndInsert
        case .meeting: .stop
        default: nil
        }
    }
}
