import XCTest
@testable import LocalVoiceKeyboard

final class DiagnosticsTests: XCTestCase {
    func testRedactsDescriptionsUserInfoAndUnknownDomains() throws {
        let secret = "private transcript and contact"
        let error = NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: "/private/" + secret])
        let event = DiagnosticEvent(operation: "test.failure", error: error)
        let data = try JSONEncoder().encode(event)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        XCTAssertTrue(event.domain.hasPrefix("domain-"))
        XCTAssertEqual(event.code, 42)
    }
    func testEventRetentionDeduplicationAndCorruptionRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiagnosticStore(root: root, process: "test")
        let date = Date()
        for i in 0..<120 {
            try store.append(DiagnosticEvent(operation: "test.failure", error: NSError(domain: NSCocoaErrorDomain, code: i), now: date))
        }
        XCTAssertEqual(try store.readEvents().count, 100)
        XCTAssertEqual(try store.readEvents().first?.code, 20)
        try store.append(DiagnosticEvent(operation: "test.failure", error: NSError(domain: NSCocoaErrorDomain, code: 119), now: date.addingTimeInterval(2)))
        XCTAssertEqual(try store.readEvents().count, 100)
        XCTAssertEqual(try store.readEvents().last?.date, date)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("test.events.json"))
        try store.append(DiagnosticEvent(operation: "test.recovery", error: CocoaError(.fileReadCorruptFile)))
        XCTAssertEqual(try store.readEvents().count, 1)
        XCTAssertThrowsError(try DiagnosticStore(root: root, process: "../escape"))
    }
    func testMetricPayloadValidationDeduplicationAndBoundedRetention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiagnosticStore(root: root, process: "test")
        for i in 0..<9 { try store.savePayload(Data("{\"sample\":\(i)}".utf8)) }
        XCTAssertEqual(try store.payloads().count, 5)
        let existing = try Data(contentsOf: XCTUnwrap(store.payloads().first))
        try store.savePayload(existing)
        XCTAssertEqual(try store.payloads().count, 5)
        XCTAssertThrowsError(try store.savePayload(Data("not JSON".utf8)))
        XCTAssertThrowsError(try store.savePayload(Data(repeating: 0, count: DiagnosticStore.payloadByteLimit + 1)))
        XCTAssertEqual(try store.payloads().count, 5)
    }
}
