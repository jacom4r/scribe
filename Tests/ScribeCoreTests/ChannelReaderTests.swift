import AVFoundation
import Foundation
import Testing
@testable import ScribeCore

@Suite struct ChannelReaderTests {
    private func tempURL(_ ext: String = "wav") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(UUID().uuidString).\(ext)")
    }

    /// 48 kHz stereo WAV via WavWriter: 440 Hz sine at 0.5 on the left, silence on the right.
    private func writeSineWav(seconds: Double) throws -> URL {
        let url = tempURL()
        let writer = try WavWriter(url: url, inputSampleRate: 48_000)
        let chunk = 4800
        let buffer = StereoBuffer(capacityFrames: chunk)
        let total = Int(seconds * 48_000)
        var written = 0
        while written < total {
            let n = min(chunk, total - written)
            for f in 0..<n {
                let t = Double(written + f) / 48_000
                buffer.samples[2 * f] = Float(0.5 * sin(2 * .pi * 440 * t))
                buffer.samples[2 * f + 1] = 0
            }
            try writer.write(frames: UInt32(n), buffer.bufferList(frames: n))
            written += n
        }
        try writer.close()
        return url
    }

    @Test func splitsAndResamplesTo16k() throws {
        let url = try writeSineWav(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let tracks = try ChannelReader.read(url)

        #expect(abs(tracks.left.count - 32_000) <= 64)
        #expect(tracks.right.count == tracks.left.count)
        #expect(abs(tracks.duration - 2.0) < 0.01)

        let rms = sqrt(tracks.left.reduce(0) { $0 + Double($1 * $1) } / Double(tracks.left.count))
        #expect(abs(rms - 0.3536) < 0.02)              // 0.5 / sqrt(2)
        #expect(tracks.right.allSatisfy { abs($0) < 1e-4 })
        #expect(tracks.left.allSatisfy { $0 >= -1 && $0 <= 1 })
    }

    @Test func monoFileThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        try file.write(from: buffer)

        #expect(throws: ScribeError.self) { try ChannelReader.read(url) }
    }

    @Test func missingFileThrows() {
        #expect(throws: ScribeError.self) { try ChannelReader.read(tempURL()) }
    }

    @Test func emptyFileThrows() throws {
        let url = try writeSineWav(seconds: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ScribeError.self) { try ChannelReader.read(url) }
    }
}
