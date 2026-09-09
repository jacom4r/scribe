import AudioToolbox
import CoreAudio
import Foundation

/// Writes interleaved Float32 stereo audio to a 16-bit PCM stereo WAV at 48 kHz.
/// `writeAsync` is safe on the real-time audio thread once `prime()` has run.
///
/// Synchronization contract (this is what justifies `@unchecked Sendable`):
/// `file` is read on the real-time thread by `writeAsync` and cleared by
/// `close()` without any lock, by design — a lock on the audio thread is not
/// real-time safe. Callers must therefore stop the IO proc before closing:
/// `CaptureEngine.stop()` is synchronous and returns only once Core Audio has
/// torn the proc down, so no `writeAsync` can be in flight after it. Calling
/// `close()` while an IO proc is still running is a use-after-free.
public final class WavWriter: @unchecked Sendable {
    public static let fileSampleRate: Double = 48_000

    public let url: URL
    private var file: ExtAudioFileRef?

    public init(url: URL, inputSampleRate: Double) throws {
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: Self.fileSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: inputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)

        var ref: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileWAVEType, &fileFormat, nil,
            AudioFileFlags.eraseFile.rawValue, &ref)
        guard status == noErr, let created = ref else {
            throw ScribeError.writeFailed(status)
        }
        status = ExtAudioFileSetProperty(
            created, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard status == noErr else {
            ExtAudioFileDispose(created)
            throw ScribeError.writeFailed(status)
        }
        self.url = url
        self.file = created
    }

    /// Call once from a non-real-time thread before the first `writeAsync`.
    public func prime() throws {
        guard let file else { throw ScribeError.writeFailed(kAudioFileNotOpenError) }
        let status = ExtAudioFileWriteAsync(file, 0, nil)
        guard status == noErr else { throw ScribeError.writeFailed(status) }
    }

    /// Real-time safe. Returns a status instead of throwing so the audio
    /// thread can flag failure without unwinding.
    public func writeAsync(frames: UInt32, _ list: UnsafePointer<AudioBufferList>) -> OSStatus {
        guard let file else { return kAudioFileNotOpenError }
        return ExtAudioFileWriteAsync(file, frames, list)
    }

    /// Blocking write for tests and tools. Not for the audio thread.
    public func write(frames: UInt32, _ list: UnsafePointer<AudioBufferList>) throws {
        guard let file else { throw ScribeError.writeFailed(kAudioFileNotOpenError) }
        let status = ExtAudioFileWrite(file, frames, list)
        guard status == noErr else { throw ScribeError.writeFailed(status) }
    }

    /// Flushes pending async writes and finalizes the header. Idempotent.
    ///
    /// Not safe to call concurrently with `writeAsync`: stop the IO proc first
    /// (`CaptureEngine.stop()`, which is synchronous). See the type's doc
    /// comment for the full contract.
    public func close() throws {
        guard let file else { return }
        self.file = nil
        let status = ExtAudioFileDispose(file)
        guard status == noErr else { throw ScribeError.writeFailed(status) }
    }

    deinit {
        try? close()
    }
}
