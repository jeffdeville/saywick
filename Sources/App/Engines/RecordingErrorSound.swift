@preconcurrency import AVFoundation
import Foundation

/// Retains playback while the app is backgrounded. Capture must stop first:
/// its record-only audio session cannot play an alert.
@MainActor
final class RecordingErrorSound {
    static let shared = RecordingErrorSound()
    private var player: AVAudioPlayer?
    private var completion: Task<Void, Never>?

    func play() {
        stop()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.tone())
            self.player = player
            guard player.play() else {
                stop()
                ActivationDiagnostics.shared.record("Recording error sound could not start")
                return
            }
            completion = Task { [weak self] in
                try? await Task.sleep(for: .seconds(player.duration + 0.1))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            // An ongoing system interruption can deny playback too.
            DiagnosticLog.error("audio.error-sound", error)
            let failure = error as NSError
            ActivationDiagnostics.shared.record("Recording error sound unavailable: \(failure.domain)/\(failure.code)")
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stop() {
        completion?.cancel()
        completion = nil
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Two descending notes, with short fades to avoid clicks. Mono PCM WAV.
    static func tone() -> Data {
        let rate = 22_050
        let count = rate * 3 / 4
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(rate))
        word(UInt32(rate * 2)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let local = time < 0.35 ? time : time - 0.4
            let envelope = max(0, min(1, local / 0.015, (0.3 - local) / 0.025))
            let frequency = time < 0.35 ? 880.0 : 587.33
            word(Int16(sin(2 * .pi * frequency * local) * envelope * 16_000))
        }
        return data
    }
}
