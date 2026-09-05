@preconcurrency import AVFoundation
import Foundation

private final class SingleBufferInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var hasSuppliedBuffer = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !hasSuppliedBuffer else { return nil }
        hasSuppliedBuffer = true
        return buffer
    }
}

final class AudioBufferConverter {
    enum ConversionError: LocalizedError {
        case failedToCreateConverter
        case failedToCreateBuffer
        case conversionFailed(NSError?)

        var errorDescription: String? {
            switch self {
            case .failedToCreateConverter:
                "Could not create an audio converter."
            case .failedToCreateBuffer:
                "Could not allocate a converted audio buffer."
            case .conversionFailed(let error):
                error?.localizedDescription ?? "Audio conversion failed."
            }
        }
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw ConversionError.failedToCreateConverter }

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: capacity
        ) else {
            throw ConversionError.failedToCreateBuffer
        }

        var underlyingError: NSError?
        let input = SingleBufferInput(buffer)
        let status = converter.convert(to: converted, error: &underlyingError) { _, inputStatus in
            if let buffer = input.take() {
                inputStatus.pointee = .haveData
                return buffer
            }
            inputStatus.pointee = .noDataNow
            return nil
        }

        guard status != .error else {
            throw ConversionError.conversionFailed(underlyingError)
        }
        return converted
    }
}
