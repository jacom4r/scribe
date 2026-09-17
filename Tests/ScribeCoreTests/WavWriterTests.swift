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

    @Test func resamples24kInputTo48kFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 24_000)
        let buffer = StereoBuffer(capacityFrames: 4800)
        fill(buffer, frames: 4800, left: 0.5, right: 0)

        try writer.write(frames: 4800, buffer.bufferList(frames: 4800))
        try writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48_000)
        // 4800 frames at 24 kHz is 0.2 s, which is 9600 frames at 48 kHz.
        // Sample rate conversion has filter latency, so allow a small margin
        // rather than asserting an exact count.
        #expect(abs(file.length - 9600) <= 128)
    }

    @Test func resamplesChunkedAsyncWrites() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 24_000)
        try writer.prime()

        // 512-frame blocks, the size a real IO proc delivers. 24 blocks is
        // 12288 frames at 24 kHz, which is 24576 frames at 48 kHz.
        let buffer = StereoBuffer(capacityFrames: 512)
        fill(buffer, frames: 512, left: 0.25, right: 0)
        for _ in 0..<24 {
            #expect(writer.writeAsync(frames: 512, buffer.bufferList(frames: 512)) == noErr)
        }
        try writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(abs(file.length - 24576) <= 256)

        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                   frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: pcm)
        // Past the converter's filter latency the signal must be present.
        #expect(abs(pcm.floatChannelData![0][12000] - 0.25) < 0.01)
        #expect(abs(pcm.floatChannelData![1][12000]) < 0.001)
    }

    @Test func changesInputSampleRateMidFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 24_000)

        // 0.2 s at 24 kHz -> 9600 frames at 48 kHz.
        let low = StereoBuffer(capacityFrames: 4800)
        fill(low, frames: 4800, left: 0.5, right: 0)
        try writer.write(frames: 4800, low.bufferList(frames: 4800))

        try writer.setInputSampleRate(48_000)
        #expect(writer.inputSampleRate == 48_000)

        // 0.2 s at 48 kHz -> 9600 frames at 48 kHz.
        let high = StereoBuffer(capacityFrames: 9600)
        fill(high, frames: 9600, left: 0, right: 0.75)
        try writer.write(frames: 9600, high.bufferList(frames: 9600))
        try writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(abs(file.length - 19200) <= 128)

        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                   frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: pcm)
        let left = pcm.floatChannelData![0]
        let right = pcm.floatChannelData![1]
        // First segment: left carries 0.5, right silent.
        #expect(abs(left[4800] - 0.5) < 0.01)
        #expect(abs(right[4800]) < 0.01)
        // Second segment: right carries 0.75, left silent.
        #expect(abs(left[14400]) < 0.01)
        #expect(abs(right[14400] - 0.75) < 0.01)
    }

    @Test func changesInputSampleRateMidFileAcrossAsyncWrites() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 24_000)
        try writer.prime()

        // First segment at 24 kHz: 24 blocks of 512 frames (12288 frames in,
        // 24576 out) — the same shape as `resamplesChunkedAsyncWrites`, so the
        // `setInputSampleRate` rebuild below exercises `drainConverter()`'s
        // `ExtAudioFileWriteAsync` branch, which no other test reaches: every
        // other mid-file-rate-change test uses the synchronous `write` path.
        let low = StereoBuffer(capacityFrames: 512)
        fill(low, frames: 512, left: 0.3, right: 0)
        for _ in 0..<24 {
            #expect(writer.writeAsync(frames: 512, low.bufferList(frames: 512)) == noErr)
        }

        try writer.setInputSampleRate(48_000)
        #expect(writer.inputSampleRate == 48_000)

        // Second segment at 48 kHz (passthrough, no converter): 24 more
        // 512-frame blocks (12288 frames, 1:1 into the file).
        let high = StereoBuffer(capacityFrames: 512)
        fill(high, frames: 512, left: 0, right: 0.6)
        for _ in 0..<24 {
            #expect(writer.writeAsync(frames: 512, high.bufferList(frames: 512)) == noErr)
        }
        try writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48_000)
        // Expected: 24576 (converted first segment) + 12288 (passthrough
        // second segment) = 36864. Sample rate conversion has filter latency;
        // measured slack was 32 frames. The tolerance below is set well above
        // that measurement but still under one `writeAsync` chunk (512 frames).
        let expectedTotal = 24576 + 12288
        #expect(abs(file.length - AVAudioFramePosition(expectedTotal)) <= 128)

        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                   frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: pcm)
        let left = pcm.floatChannelData![0]
        let right = pcm.floatChannelData![1]
        // Well inside the first (converted) segment: left carries 0.3, right
        // silent.
        #expect(abs(left[12000] - 0.3) < 0.01)
        #expect(abs(right[12000]) < 0.01)
        // Well inside the second (passthrough) segment, past the seam: right
        // carries 0.6, left silent.
        #expect(abs(left[30000]) < 0.01)
        #expect(abs(right[30000] - 0.6) < 0.01)
    }

    @Test func settingTheSameInputSampleRateIsANoOp() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 48_000)
        let buffer = StereoBuffer(capacityFrames: 4800)
        fill(buffer, frames: 4800, left: 0.5, right: 0)

        try writer.write(frames: 4800, buffer.bufferList(frames: 4800))
        try writer.setInputSampleRate(48_000)
        try writer.write(frames: 4800, buffer.bufferList(frames: 4800))
        try writer.close()

        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 9600)
    }

    @Test func settingANonFiniteInputSampleRateThrowsAndLeavesRateUnchanged() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavWriter(url: url, inputSampleRate: 24_000)

        #expect(throws: (any Error).self) {
            try writer.setInputSampleRate(.infinity)
        }
        #expect(writer.inputSampleRate == 24_000)

        #expect(throws: (any Error).self) {
            try writer.setInputSampleRate(.nan)
        }
        #expect(writer.inputSampleRate == 24_000)

        try writer.close()
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
