import AudioToolbox
import Foundation

/// A Scribe recording split into its two channels at the speech models' rate.
public struct ChannelTracks: Sendable {
    /// Mic channel, 16 kHz mono.
    public var left: [Float]
    /// System-audio channel, 16 kHz mono.
    public var right: [Float]
    public var duration: TimeInterval

    public init(left: [Float], right: [Float], duration: TimeInterval) {
        self.left = left
        self.right = right
        self.duration = duration
    }
}

/// Streams a stereo WAV through `ExtAudioFile` with a 16 kHz Float32 client
/// format, so Core Audio resamples on the way in and the 48 kHz file is never
/// held in memory. Peak memory is the two 16 kHz tracks plus one block.
public enum ChannelReader {
    public static let sampleRate: Double = 16_000
    static let blockFrames = 65_536

    public static func read(_ url: URL) throws -> ChannelTracks {
        var ref: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(url as CFURL, &ref)
        guard status == noErr, let file = ref else {
            throw ScribeError.transcriptionFailed("couldn't open \(url.lastPathComponent) (error \(status))")
        }
        defer { ExtAudioFileDispose(file) }

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)
        guard status == noErr else {
            throw ScribeError.transcriptionFailed("couldn't read the format of \(url.lastPathComponent) (error \(status))")
        }
        guard fileFormat.mChannelsPerFrame == 2 else {
            throw ScribeError.transcriptionFailed(
                "expected a stereo recording, got \(fileFormat.mChannelsPerFrame) channel(s)")
        }

        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else {
            throw ScribeError.transcriptionFailed("couldn't set up resampling (error \(status))")
        }

        var left: [Float] = []
        var right: [Float] = []
        var scratch = [Float](repeating: 0, count: blockFrames * 2)
        while true {
            var frames = UInt32(blockFrames)
            let readStatus = scratch.withUnsafeMutableBufferPointer { buf -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(buf.count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(buf.baseAddress)))
                return ExtAudioFileRead(file, &frames, &list)
            }
            guard readStatus == noErr else {
                throw ScribeError.transcriptionFailed("couldn't read \(url.lastPathComponent) (error \(readStatus))")
            }
            if frames == 0 { break }
            let n = Int(frames)
            left.reserveCapacity(left.count + n)
            right.reserveCapacity(right.count + n)
            for f in 0..<n {
                left.append(min(max(scratch[2 * f], -1), 1))
                right.append(min(max(scratch[2 * f + 1], -1), 1))
            }
        }

        guard !left.isEmpty else {
            throw ScribeError.transcriptionFailed("\(url.lastPathComponent) contains no audio")
        }
        return ChannelTracks(left: left, right: right, duration: Double(left.count) / sampleRate)
    }
}
