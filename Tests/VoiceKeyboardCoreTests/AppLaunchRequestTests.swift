import XCTest
@testable import VoiceKeyboardCore

final class AppLaunchRequestTests: XCTestCase {
    func testOnlyRecentShortcutRequestsAreFresh() throws {
        let time = Date(timeIntervalSince1970: 1_000)
        let request = AppLaunchRequest(action: .start, createdAt: time)
        XCTAssertTrue(request.isFresh(at: time))
        XCTAssertTrue(request.isFresh(at: time.addingTimeInterval(30)))
        XCTAssertFalse(request.isFresh(at: time.addingTimeInterval(31)))
        XCTAssertFalse(request.isFresh(at: time.addingTimeInterval(-1)))
        let restored = try JSONDecoder().decode(AppLaunchRequest.self, from: JSONEncoder().encode(request))
        XCTAssertFalse(restored.isFresh(at: time.addingTimeInterval(3600)))
    }
}
