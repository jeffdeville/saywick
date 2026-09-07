import CryptoKit
import Foundation

/// Downloads only when Parakeet is explicitly prepared. Never bundle model weights.
actor ParakeetModelStore {
    static let shared = ParakeetModelStore()
    static let filename = "parakeet-unified-en-0.6b-Q8_0.gguf"
    static let sha256 = "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"
    private var pending: Task<URL, Error>?
    private var verified: URL?

    func modelURL(allowDownload: Bool = true) async throws -> URL {
        if let verified, FileManager.default.fileExists(atPath: verified.path) { return verified }
        if let pending { return try await pending.value }
        let task = Task { try await Self.obtain(allowDownload: allowDownload) }
        pending = task
        defer { pending = nil }
        let url = try await task.value
        verified = url
        return url
    }

    private static func obtain(allowDownload: Bool) async throws -> URL {
        let manager = FileManager.default
        var directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true).appendingPathComponent("Parakeet", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let target = directory.appendingPathComponent(filename)
        if manager.fileExists(atPath: target.path) {
            if try valid(target) { return target }
            try manager.removeItem(at: target)
        }
        guard allowDownload else {
            throw SpeechEngineError.unavailable("Open Saywick and start a dictation once to download Parakeet before using the background shortcut.")
        }
        let url = URL(string: "https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/resolve/7e948f21b7bdbac698d3318db9d350f1096f3b6c/\(filename)")!
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? manager.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, try valid(temporary) else {
            throw SpeechEngineError.unavailable("Parakeet model download failed verification. Please try again on Wi-Fi.")
        }
        try manager.moveItem(at: temporary, to: target)
        return target
    }

    private static func valid(_ url: URL) throws -> Bool {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == 731_357_568 else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }
}
