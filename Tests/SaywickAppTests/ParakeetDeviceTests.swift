import AVFoundation
import Darwin
import TranscribeCpp
import UIKit
import XCTest
@testable import LocalVoiceKeyboard

/// Opt-in: stage Documents/ParakeetBench/manifest.json and PCM16 WAVs first.
/// Never downloads weights or records the microphone during ordinary unit tests.
@MainActor
final class ParakeetDeviceTests: XCTestCase {
    struct Fixture: Codable { let wav: String; let handy: String; let paced: Bool }
    struct Result: Codable {
        let wav: String
        let text: String
        let handy: String
        let backend: String
        let audioSeconds: Double
        let elapsedSeconds: Double
        let inferenceSeconds: Double
        let loadSeconds: Double
        let peakLagSeconds: Double
        let firstPartialSeconds: Double?
        let stopSeconds: Double
        let peakFootprintMB: Double
        let thermalStart: Int
        let thermalEnd: Int
        let batteryStart: Float
        let batteryEnd: Float
        let batteryState: Int
    }

    func testStagedRecordings() async throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ParakeetBench")
        let manifest = folder.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw XCTSkip("Stage ParakeetBench fixtures to opt into native device benchmarks.")
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: manifest))
        let modelURL = try await ParakeetModelStore.shared.modelURL()
        UIDevice.current.isBatteryMonitoringEnabled = true
        defer { UIDevice.current.isBatteryMonitoringEnabled = false }
        var results: [Result] = []
        var audioPosition: Double = 0
        let monitor = Task {
            while !Task.isCancelled {
                let message = "audioSeconds=\(audioPosition) footprintMB=\(Self.footprintMB()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) at=\(Date())"
                try? message.write(to: folder.appendingPathComponent("progress.txt"), atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { monitor.cancel() }
        for fixture in fixtures {
            let worker = ParakeetWorker()
            print("Parakeet benchmark: loading model for \(fixture.wav)")
            let loadStart = Date()
            try await worker.prepare(modelURL: modelURL)
            let loadSeconds = Date().timeIntervalSince(loadStart)
            print("Parakeet benchmark: model ready, footprint \(Self.footprintMB()) MB")
            let file = try AVAudioFile(forReading: folder.appendingPathComponent(fixture.wav), commonFormat: .pcmFormatFloat32, interleaved: false)
            XCTAssertEqual(file.processingFormat.sampleRate, 16000)
            XCTAssertEqual(file.processingFormat.channelCount, 1)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            let start = Date()
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            let battery = UIDevice.current.batteryLevel
            var inference: Double = 0
            var peakLag: Double = 0
            var firstPartial: Double?
            audioPosition = 0
            var peak = Self.footprintMB()
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer)
                if fixture.paced {
                    let deadline = Double(file.framePosition) / 16000
                    let wait = deadline - Date().timeIntervalSince(start)
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                }
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                let feedStart = Date()
                let partial = try await worker.feed(samples)
                if firstPartial == nil, let partial, !partial.isEmpty { firstPartial = Date().timeIntervalSince(start) }
                inference += Date().timeIntervalSince(feedStart)
                audioPosition = Double(file.framePosition) / 16000
                if fixture.paced { peakLag = max(peakLag, Date().timeIntervalSince(start) - audioPosition) }
                peak = max(peak, Self.footprintMB())
            }
            let stopStart = Date()
            let text = try await worker.finish()
            let stop = Date().timeIntervalSince(stopStart)
            let result = Result(wav: fixture.wav, text: text, handy: fixture.handy, backend: "cpu-accelerate-4-threads-armv8.2-dotprod",
                                audioSeconds: Double(file.length) / 16000,
                                elapsedSeconds: Date().timeIntervalSince(start), inferenceSeconds: inference,
                                loadSeconds: loadSeconds, peakLagSeconds: peakLag, firstPartialSeconds: firstPartial,
                                stopSeconds: stop, peakFootprintMB: peak, thermalStart: thermal,
                                thermalEnd: ProcessInfo.processInfo.thermalState.rawValue,
                                batteryStart: battery, batteryEnd: UIDevice.current.batteryLevel,
                                batteryState: UIDevice.current.batteryState.rawValue)
            results.append(result)
            let data = try JSONEncoder().encode(results)
            try data.write(to: folder.appendingPathComponent("results.json"), options: .atomic)
            XCTAssertFalse(text.isEmpty, fixture.wav)
            // Idempotent Stop must not duplicate the transcript or retain native handles.
            let repeated = try await worker.finish()
            XCTAssertEqual(repeated, "")
        }
        // Opt in again by staging a manifest for the next run. Remove this
        // exact file inside the app; device transfer cleanup can clear a domain.
        try FileManager.default.removeItem(at: manifest)
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
