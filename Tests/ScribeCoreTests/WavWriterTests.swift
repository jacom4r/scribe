import AVFoundation
import Foundation
import Testing
@testable import ScribeCore

@Suite struct WavWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(UUID().uuidString).wav")
    }

    private func fill(_ buffer: StereoBuffer, frames: Int, left: Float, right: Float) {
        for f in 0..<frames {
            buffer.samples[2 * f] = left
            buffer.samples[2 * f + 1] = right
        }
    }

    @Test func writesStereo16BitWavAt48k() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 48_000)
        let buffer = StereoBuffer(capacityFrames: 4800)
        fill(buffer, frames: 4800, left: 0.5, right: 0)

        try writer.write(frames: 4800, buffer.bufferList(frames: 4800))
        try writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(file.length == 4800)

        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
        try file.read(into: pcm)
        let left = pcm.floatChannelData![0]
        let right = pcm.floatChannelData![1]
        #expect(abs(left[100] - 0.5) < 0.001)
        #expect(abs(right[100]) < 0.001)
    }

    @Test func asyncWritesAreFlushedOnClose() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 48_000)
        let buffer = StereoBuffer(capacityFrames: 480)
        fill(buffer, frames: 480, left: 0.25, right: -0.25)

        try writer.prime()
        for _ in 0..<10 {
            #expect(writer.writeAsync(frames: 480, buffer.bufferList(frames: 480)) == noErr)
        }
        try writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 4800)
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800)!
        try file.read(into: pcm)
        #expect(abs(pcm.floatChannelData![1][4000] - -0.25) < 0.001)
    }

    @Test func resamplesFrom44100() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 44_100)
        let buffer = StereoBuffer(capacityFrames: 4410)
        fill(buffer, frames: 4410, left: 0.5, right: 0.5)

        try writer.write(frames: 4410, buffer.bufferList(frames: 4410))
        try writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(abs(Int(file.length) - 4800) <= 64)
    }

    @Test func closeIsIdempotent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 48_000)
        try writer.close()
        try writer.close()
    }

    @Test func stereoBufferListReportsRequestedFrames() {
        let buffer = StereoBuffer(capacityFrames: 100)
        let list = buffer.bufferList(frames: 10)
        #expect(list.pointee.mNumberBuffers == 1)
        #expect(list.pointee.mBuffers.mNumberChannels == 2)
        #expect(list.pointee.mBuffers.mDataByteSize == 10 * 2 * 4)
    }
}
