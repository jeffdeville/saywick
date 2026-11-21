import CryptoKit
import XCTest
@testable import LocalVoiceKeyboard

private actor DownloadFixture {
    var calls = 0
    let root: URL
    let data: Data
    var status = 200
    init(root: URL, data: Data) { self.root = root; self.data = data }
    func setStatus(_ value: Int) { status = value }
    func download(_ url: URL) async throws -> (URL, URLResponse) {
        calls += 1
        try await Task.sleep(for: .milliseconds(20))
        let file = root.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        return (file, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
final class ModelDownloadTests: XCTestCase {
    func testConcurrentDownloadIntegrityCacheAndOfflineReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("small test model".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fixture = DownloadFixture(root: root, data: data)
        let cache = root.appendingPathComponent("cache")
        let model = ParakeetModelStore(root: cache, expectedSize: data.count, expectedHash: digest, download: { try await fixture.download($0) })
        async let first = model.modelURL()
        async let second = model.modelURL()
        let (a,b) = try await (first,second)
        XCTAssertEqual(a,b)
        let calls = await fixture.calls; XCTAssertEqual(calls,1)
        XCTAssertEqual(try Data(contentsOf: a),data)
        let offline = ParakeetModelStore(root: cache, expectedSize: data.count, expectedHash: digest, download: { _ in throw URLError(.notConnectedToInternet) })
        let reused = try await offline.modelURL(allowDownload: false); XCTAssertEqual(reused,a)
    }
    func testBadResponseAndCorruptCacheAreRejectedThenRetrySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("valid".utf8)
        let fixture = DownloadFixture(root: root, data: data)
        let cache = root.appendingPathComponent("cache")
        let model = ParakeetModelStore(root: cache, expectedSize: data.count,
            expectedHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), download: { try await fixture.download($0) })
        do { _ = try await model.modelURL(allowDownload: false); XCTFail("Offline cache missing") } catch {}
        try Data("wrong".utf8).write(to: cache.appendingPathComponent(ParakeetModelStore.filename))
        await fixture.setStatus(500)
        do { _ = try await model.modelURL(); XCTFail("HTTP failure must not install") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(ParakeetModelStore.filename).path))
        await fixture.setStatus(200)
        let url = try await model.modelURL(); XCTAssertEqual(try Data(contentsOf: url),data)
        let calls = await fixture.calls; XCTAssertEqual(calls,2)
    }
}
