@preconcurrency import AVFoundation
import Foundation
import VoiceKeyboardCore

/// One hardware capture graph for every engine. Keeping the graph running lets
/// the user begin another dictation while the containing app is backgrounded.
/// With no consumer, buffers are discarded before any copying or persistence.
@MainActor
final class MicrophoneCapture {
    static let shared = MicrophoneCapture()
    private let engine = AVAudioEngine()
    private let delivery = MicrophoneDelivery()
    private(set) var keepsSessionAlive = false
    private var tapped = false
    var isRunning: Bool { engine.isRunning }

    func configure() throws {
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // Capture has no playback graph; request only microphone hardware.
        try session.setCategory(.record, mode: .measurement)
        do { try session.setActive(true) }
        catch {
            let failure = error as NSError
            ActivationDiagnostics.shared.record("Microphone activation failed: \(failure.domain)/\(failure.code)")
            throw error
        }
    }

    func beginSession() throws {
        try start()
        keepsSessionAlive = true
    }

    func setConsumer(_ consumer: @escaping MicrophoneDelivery.Consumer) {
        delivery.setConsumer(consumer)
    }

    func removeConsumer() { delivery.setConsumer(nil) }

    func start() throws {
        guard !engine.isRunning else { return }
        try configure()
        if !tapped {
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw SpeechEngineError.unavailable("The microphone is unavailable. Open Saywick to activate it again.")
            }
            let delivery = self.delivery
            node.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, time in
                delivery.receive(buffer, at: time)
            }
            tapped = true
        }
        engine.prepare()
        do { try engine.start() }
        catch {
            let failure = error as NSError
            ActivationDiagnostics.shared.record("Microphone engine failed: \(failure.domain)/\(failure.code)")
            throw error
        }
    }

    /// A dictation stops delivery, but a user-enabled keyboard session retains
    /// the same input graph and audio session across finalization and idle time.
    func stop() {
        removeConsumer()
        guard !keepsSessionAlive else { return }
        shutdown()
    }

    func endSession() {
        keepsSessionAlive = false
        shutdown()
    }

    func deactivateIfUnused() {
        guard !keepsSessionAlive, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func shutdown() {
        removeConsumer()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
        deactivateIfUnused()
    }
}

/// The audio callback and main actor share only this locked delivery gate.
/// Removal waits for an in-flight callback so no old audio enters the next run.
final class MicrophoneDelivery: @unchecked Sendable {
    typealias Consumer = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private let lock = NSLock()
    private var consumer: Consumer?

    func setConsumer(_ consumer: Consumer?) {
        lock.lock()
        defer { lock.unlock() }
        self.consumer = consumer
    }

    func receive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        consumer?(buffer, time)
    }
}
