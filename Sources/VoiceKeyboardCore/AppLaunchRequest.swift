import Foundation

public struct AppLaunchRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case start, history }
    public let action: Action
    public let createdAt: Date
    public init(action: Action, createdAt: Date = Date()) {
        self.action = action; self.createdAt = createdAt
    }
    public func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age >= 0 && age <= 30
    }
}
