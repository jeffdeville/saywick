@preconcurrency import AVFoundation
import Foundation

/// Written from the owning engine's serial main-actor audio consumer, never
/// from the realtime tap. The file also survives failed network requests.
@MainActor
final class AudioArchive {
    let url: URL
    private var file: AVAudioFile?
    private let converter = AudioBufferConverter()
    static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    }
    init(url: URL) throws {
        self.url = url
        file = try AVAudioFile(forWriting: url, settings: Self.format.settings,
                               commonFormat: .pcmFormatInt16, interleaved: false)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
    }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        try file?.write(from: converter.convert(buffer, to: Self.format))
    }
    func close() { file = nil }
    func reset() throws {
        close()
        file = try AVAudioFile(forWriting: url, settings: Self.format.settings,
                               commonFormat: .pcmFormatInt16, interleaved: false)
    }
}

final class OwnedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init?(_ source: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in input.indices {
            guard let src = input[i].mData, let dst = output[i].mData else { return nil }
            memcpy(dst, src, Int(input[i].mDataByteSize))
        }
        buffer = copy
    }
}
