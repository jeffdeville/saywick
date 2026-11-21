import Foundation
import XCTest
@testable import LocalVoiceKeyboard

final class CleanupTemplateTests: XCTestCase {
    func testCatalogRoundTripAndRename() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = CleanupTemplates(defaults: defaults)
        var item = CleanupTemplate(name: " Journal ", prompt: "Summarize\nunder headings")
        try catalog.save(item)
        let restored = CleanupTemplates(defaults: defaults)
        XCTAssertEqual(restored.items.first?.name, "Journal")
        XCTAssertEqual(restored.items.first?.prompt, item.prompt)
        XCTAssertThrowsError(try restored.save(CleanupTemplate(name: "journal", prompt: "Group")))
        item.name = "Log"
        try restored.save(item)
        XCTAssertEqual(restored.items, [item])
        try restored.remove(item.id)
        XCTAssertTrue(CleanupTemplates(defaults: defaults).items.isEmpty)
    }

    func testWholeEntryRequestPreservesMultilineResult() async throws {
        let first = String(repeating: "morning ", count: 600)
        let input = first + "evening"
        let prompt = String(repeating: "Group by time of day. ", count: 35)
        let expected = "# Morning\n\nFirst event\n\n# Evening\n\nSecond event."
        var requests = 0
        let result = try await TranscriptPostProcessor.applyTemplate(prompt, to: input, readKey: { "test" }) { request in
            requests += 1
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [["role": "system", "content": prompt], ["role": "user", "content": input]])
            return try Self.response(for: request, content: expected, reason: "stop")
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(result, expected)
    }

    func testIncompleteTemplateResultsAreRejected() async throws {
        for (content, reason) in [("partial", "length"), ("", "stop"), ("filtered", "content_filter")] {
            do {
                _ = try await TranscriptPostProcessor.applyTemplate("Summarize", to: "entry", readKey: { "test" }) {
                    try Self.response(for: $0, content: content, reason: reason)
                }
                XCTFail("Accepted incomplete result")
            } catch PostProcessingError.openAIUnavailable {}
        }
    }

    private static func response(for request: URLRequest, content: String, reason: String) throws -> (Data, URLResponse) {
        let body = try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": reason, "message": ["content": content]]]
        ])
        return (body, try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                                   httpVersion: nil, headerFields: nil)))
    }
}
