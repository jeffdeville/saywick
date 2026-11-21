import Foundation

public enum DictationState: String, Codable, Sendable { case inactive, activated, transcribing, postProcess }
public enum SessionOperation: String, Codable, Sendable { case activating, starting, cancelling, deactivating }

/// The sole recording lifecycle. Results and transport availability are separate.
public struct DictationSession: Equatable, Codable, Sendable {
    public private(set) var state: DictationState = .inactive
    public private(set) var pending: SessionOperation?
    public private(set) var generation = UUID()
    public private(set) var idleDeadline: Date?
    public private(set) var issue: String?
    public var isBusy: Bool { pending != nil || state == .transcribing || state == .postProcess }
    public var ownsMicrophone: Bool { state != .inactive }
    public init() {}

    public enum Event: Sendable {
        case activate, activated(UUID, Date), start, started(UUID)
        case finish, completed(UUID, retain: Bool, at: Date)
        case cancel, deactivate, settled(UUID, retain: Bool, at: Date)
        case failure(String), expire(Date), clearIssue
    }
    public enum Effect: Equatable, Sendable { case activate, start, finish, cancel, release, alert, none, rejected }

    @discardableResult
    public mutating func send(_ event: Event) -> Effect {
        switch event {
        case .activate:
            guard state == .inactive, pending == nil else { return .rejected }
            generation = UUID(); issue = nil; pending = .activating; return .activate
        case .activated(let token, let now):
            guard token == generation, pending == .activating else { return .rejected }
            pending = nil; state = .activated; idleDeadline = KeyboardReadiness.deadline(after: now); return .none
        case .start:
            guard state == .activated, pending == nil else { return .rejected }
            generation = UUID(); pending = .starting; idleDeadline = nil; issue = nil; return .start
        case .started(let token):
            guard token == generation, pending == .starting else { return .rejected }
            pending = nil; state = .transcribing; return .none
        case .finish:
            guard state == .transcribing, pending == nil else { return .rejected }
            state = .postProcess; return .finish
        case .completed(let token, let retain, let now):
            guard token == generation, state == .postProcess, pending == nil else { return .rejected }
            settle(retain: retain, at: now); return retain ? .none : .release
        case .cancel:
            guard state == .transcribing, pending == nil else { return .rejected }
            generation = UUID(); pending = .cancelling; return .cancel
        case .deactivate:
            guard pending == nil, state == .activated else { return .rejected }
            generation = UUID(); pending = .deactivating; idleDeadline = nil; return .release
        case .settled(let token, let retain, let now):
            guard token == generation, pending == .cancelling || pending == .deactivating else { return .rejected }
            settle(retain: retain, at: now); return .none
        case .failure(let message):
            guard (isBusy || ownsMicrophone), !(state == .inactive && pending == .deactivating) else { return .rejected }
            generation = UUID(); state = .inactive; pending = .deactivating
            idleDeadline = nil; issue = message; return .alert
        case .expire(let now):
            guard state == .activated, pending == nil, let idleDeadline, now >= idleDeadline else { return .none }
            return send(.deactivate)
        case .clearIssue: issue = nil; return .none
        }
    }
    private mutating func settle(retain: Bool, at now: Date) {
        pending = nil; state = retain ? .activated : .inactive
        idleDeadline = retain ? KeyboardReadiness.deadline(after: now) : nil
    }
}

public struct CommandAcknowledgment: Codable, Equatable, Sendable {
    public let id: UUID
    public let rejection: String?
    public init(id: UUID, rejection: String? = nil) { self.id = id; self.rejection = rejection }
}

/// Receipts never modify the recorder's snapshot, including while it is suspended.
public struct ResultReceipt: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable { case inserted, dismissed }
    public let resultID: UUID
    public let disposition: Disposition
    public init(resultID: UUID, disposition: Disposition) { self.resultID = resultID; self.disposition = disposition }
}

public struct PendingKeyboardCommand: Sendable {
    public let command: VoiceCommand
    public let sentAt: Date
    public init(command: VoiceCommand, sentAt: Date = Date()) { self.command = command; self.sentAt = sentAt }
    public func timedOut(at now: Date) -> Bool { now.timeIntervalSince(sentAt) >= 5 }
}
