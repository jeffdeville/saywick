import Foundation

/// Heartbeat from the keyboard extension, separate from transcript commands.
public struct KeyboardPresence: Codable, Sendable {
    public var keyboardID: UUID
    public var isVisible: Bool
    public var lastVisibleAt: Date
    public var updatedAt: Date

    public init(keyboardID: UUID, isVisible: Bool, lastVisibleAt: Date, updatedAt: Date) {
        self.keyboardID = keyboardID
        self.isVisible = isVisible
        self.lastVisibleAt = lastVisibleAt
        self.updatedAt = updatedAt
    }
}

/// Arms only after the keyboard is used during this recording. A missing
/// heartbeat also covers extension termination without a disappearance callback.
public struct KeyboardRecordingLifecycle: Sendable {
    public static let gracePeriod: TimeInterval = 3
    private let startedAt: Date
    private var lastPresenceAt: Date?

    public init(startedAt: Date) { self.startedAt = startedAt }

    public mutating func shouldStop(presence: KeyboardPresence?, now: Date) -> Bool {
        if let presence, presence.lastVisibleAt >= startedAt,
           presence.updatedAt <= now,
           presence.updatedAt >= (lastPresenceAt ?? startedAt) {
            lastPresenceAt = presence.updatedAt
        }
        guard let lastPresenceAt else { return false }
        return now.timeIntervalSince(lastPresenceAt) >= Self.gracePeriod
    }
}
