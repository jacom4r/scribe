import AudioToolbox
import CoreAudio
import Foundation

/// Returned by `WavWriter.inputProc` once it has handed over its block, to tell
/// `AudioConverterFillComplexBuffer` "no more input for this call" without
/// signalling end of stream. Returning 0 packets with `noErr` means end of
/// stream, which is reserved for `drainConverter()`.
private let converterInputExhausted: OSStatus = 0x7777_4945 // 'wwIE'

/// Writes interleaved Float32 stereo audio to a 16-bit PCM stereo WAV at 48 kHz.
/// `writeAsync` is safe on the real-time audio thread once `prime()` has run.
///
/// The `ExtAudioFile` client format is fixed at 48 kHz for the life of the file:
/// `kExtAudioFileProperty_ClientDataFormat` cannot be changed once any audio has
/// been written (`kExtAudioFileError_InvalidOperationOrder`), so the writer owns
/// an `AudioConverterRef` instead and rebuilds it when the input rate changes.
/// At 48 kHz in, there is no converter and input passes straight through.
///
/// Synchronization contract (this is what justifies `@unchecked Sendable`):
/// `file` and `converter` are read on the real-time thread by `writeAsync` and
/// mutated by `close()` and `setInputSampleRate(_:)` without any lock, by design
/// — a lock on the audio thread is not real-time safe. Callers must therefore
/// stop the IO proc before calling either: `CaptureEngine.stop()` is synchronous
/// and returns only once Core Audio has torn the proc down, so no `writeAsync`
/// can be in flight after it. Calling either while an IO proc is still running
/// is a use-after-free.
public final class WavWriter: @unchecked Sendable {
    public static let fileSampleRate: Double = 48_000

    public let url: URL
    public private(set) var inputSampleRate: Double

    private let maxInputFrames: Int
    private var file: ExtAudioFileRef?
    private var converter: AudioConverterRef?
    private var output: StereoBuffer?
    /// Set by `prime()`. Once async writes may be pending, anything written
    /// off the audio thread must also go through `ExtAudioFileWriteAsync` so it
    /// lands after them.
    private var primed = false

    /// Interleaved stereo Float32 at `rate`.
    private static func floatFormat(rate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }

    /// `maxInputFrames` bounds one `writeAsync` call and sizes the conversion
    /// output buffer. It matches `CaptureEngine`'s scratch capacity.
    public init(url: URL, inputSampleRate: Double, maxInputFrames: Int = 8192) throws {
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: Self.fileSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var clientFormat = Self.floatFormat(rate: Self.fileSampleRate)

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
        self.inputSampleRate = inputSampleRate
        self.maxInputFrames = maxInputFrames

        do {
            try makeConverter(rate: inputSampleRate)
        } catch {
            ExtAudioFileDispose(created)
            self.file = nil
            throw error
        }
    }

    /// Supplies the whole input block to the converter once, then returns
    /// `converterInputExhausted` so the converter stops asking for this call
    /// but stays mid-stream. With no context (`drainConverter()`), it reports
    /// end of stream: 0 packets and `noErr`. A C function pointer, so it
    /// captures nothing; the block travels through `inUserData`.
    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
        guard let raw = inUserData else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let ctx = raw.assumingMemoryBound(to: ConverterInput.self)
        if ctx.pointee.consumed {
            ioNumberDataPackets.pointee = 0
            return converterInputExhausted
        }
        ctx.pointee.consumed = true
        ioNumberDataPackets.pointee = ctx.pointee.frames
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: ctx.pointee.list))
        let destination = UnsafeMutableAudioBufferListPointer(ioData)
        destination[0] = source[0]
        outDataPacketDescription?.pointee = nil
        return noErr
    }

    /// Stack-allocated per `writeAsync` call, so nothing here allocates.
    private struct ConverterInput {
        let list: UnsafePointer<AudioBufferList>
        let frames: UInt32
        var consumed: Bool
    }

    private func disposeConverter() {
        if let converter { AudioConverterDispose(converter) }
        converter = nil
        output = nil
    }

    /// No converter at 48 kHz in: input passes straight through. Takes `rate`
    /// as a parameter rather than reading `inputSampleRate` so a caller can
    /// build (and validate) the new converter before committing to the new
    /// rate: if this throws, `inputSampleRate` is left untouched by the caller.
    private func makeConverter(rate: Double) throws {
        disposeConverter()
        guard rate != Self.fileSampleRate else { return }

        var inFormat = Self.floatFormat(rate: rate)
        var outFormat = Self.floatFormat(rate: Self.fileSampleRate)
        var ref: AudioConverterRef?
        let status = AudioConverterNew(&inFormat, &outFormat, &ref)
        guard status == noErr, let ref else { throw ScribeError.writeFailed(status) }
        converter = ref

        // Upsampling produces more frames than it consumes, so the output
        // buffer is sized for the worst case plus slack for filter latency.
        let ratio = Self.fileSampleRate / rate
        let capacity = Int((Double(maxInputFrames) * ratio).rounded(.up)) + 64
        output = StereoBuffer(capacityFrames: capacity)
    }

    /// Runs `body` with converted audio, or with the input untouched when there
    /// is no converter. Real-time safe: `body` is non-escaping and the context
    /// struct lives on the stack.
    private func converted(frames: UInt32,
                           _ list: UnsafePointer<AudioBufferList>,
                           _ body: (UInt32, UnsafePointer<AudioBufferList>) -> OSStatus) -> OSStatus {
        guard let converter, let output else { return body(frames, list) }
        guard frames > 0, Int(frames) <= maxInputFrames else { return kAudio_ParamError }

        var context = ConverterInput(list: list, frames: frames, consumed: false)
        var outFrames = UInt32(output.capacityFrames)
        let outList = UnsafeMutablePointer(
            mutating: output.bufferList(frames: output.capacityFrames))
        let status = withUnsafeMutablePointer(to: &context) { pointer in
            AudioConverterFillComplexBuffer(
                converter, Self.inputProc, pointer, &outFrames, outList, nil)
        }
        guard status == noErr || status == converterInputExhausted else { return status }
        guard outFrames > 0 else { return noErr }
        return body(outFrames, output.bufferList(frames: Int(outFrames)))
    }

    /// The first `AudioConverterFillComplexBuffer` can allocate. Run one block
    /// of silence through it here, off the audio thread, and discard the result
    /// so the audio thread never takes that cost.
    private func primeConverter() {
        guard converter != nil else { return }
        let silence = StereoBuffer(capacityFrames: 512)
        _ = converted(frames: 512, silence.bufferList(frames: 512)) { _, _ in noErr }
    }

    /// Signals end of stream to the converter and writes the latency tail it
    /// releases, so the last input frames reach the file. Not real-time safe;
    /// the IO proc must be stopped. Writes async once `prime()` has run so the
    /// tail lands after any pending async writes. Afterwards the converter is at
    /// end of stream and must be disposed or rebuilt, not written to again.
    /// Throws `ScribeError.writeFailed` if conversion or the write fails.
    private func drainConverter() throws {
        guard let file, let converter, let output else { return }
        while true {
            var outFrames = UInt32(output.capacityFrames)
            let outList = UnsafeMutablePointer(
                mutating: output.bufferList(frames: output.capacityFrames))
            var status = AudioConverterFillComplexBuffer(
                converter, Self.inputProc, nil, &outFrames, outList, nil)
            guard status == noErr else { throw ScribeError.writeFailed(status) }
            guard outFrames > 0 else { return }
            let tail = output.bufferList(frames: Int(outFrames))
            status = primed
                ? ExtAudioFileWriteAsync(file, outFrames, tail)
                : ExtAudioFileWrite(file, outFrames, tail)
            guard status == noErr else { throw ScribeError.writeFailed(status) }
        }
    }

    /// Rebuilds the internal converter for a new input rate, mid-file.
    ///
    /// Drains the current converter first so the old rate's buffered audio
    /// tail is written to the file rather than discarded, then rebuilds and
    /// re-primes for the new rate. `inputSampleRate` is only updated after the
    /// new converter has been built successfully: if `makeConverter` throws
    /// (an unsupported rate, say), the writer keeps reporting its old rate
    /// rather than a rate it never actually built a converter for. The caller
    /// is expected to stop and close the writer on failure, so there is no
    /// converter-less rate to resume writing at.
    ///
    /// Same precondition as `close()`: the caller must have stopped the IO proc
    /// first. `writeAsync` reads `converter` without a lock, so changing it
    /// under a running proc is a use-after-free.
    public func setInputSampleRate(_ rate: Double) throws {
        guard rate.isFinite, rate > 0 else { throw ScribeError.writeFailed(kAudio_ParamError) }
        guard rate != inputSampleRate else { return }
        try drainConverter()
        try makeConverter(rate: rate)
        inputSampleRate = rate
        primeConverter()
    }

    /// Call once from a non-real-time thread before the first `writeAsync`.
    public func prime() throws {
        guard let file else { throw ScribeError.writeFailed(kAudioFileNotOpenError) }
        primeConverter()
        let status = ExtAudioFileWriteAsync(file, 0, nil)
        guard status == noErr else { throw ScribeError.writeFailed(status) }
        primed = true
    }

    /// Real-time safe. Returns a status instead of throwing so the audio
    /// thread can flag failure without unwinding.
    public func writeAsync(frames: UInt32, _ list: UnsafePointer<AudioBufferList>) -> OSStatus {
        guard let file else { return kAudioFileNotOpenError }
        return converted(frames: frames, list) { outFrames, outList in
            ExtAudioFileWriteAsync(file, outFrames, outList)
        }
    }

    /// Blocking write for tests and tools. Not for the audio thread.
    public func write(frames: UInt32, _ list: UnsafePointer<AudioBufferList>) throws {
        guard let file else { throw ScribeError.writeFailed(kAudioFileNotOpenError) }
        let status = converted(frames: frames, list) { outFrames, outList in
            ExtAudioFileWrite(file, outFrames, outList)
        }
        guard status == noErr else { throw ScribeError.writeFailed(status) }
    }

    /// Drains the converter, flushes pending async writes and finalizes the
    /// header. Idempotent. The file is disposed even if the drain fails; the
    /// first error is thrown.
    ///
    /// Not safe to call concurrently with `writeAsync`: stop the IO proc first
    /// (`CaptureEngine.stop()`, which is synchronous). See the type's doc
    /// comment for the full contract.
    public func close() throws {
        guard let file else { return }
        var drainError: Error?
        do { try drainConverter() } catch { drainError = error }
        self.file = nil
        let status = ExtAudioFileDispose(file)
        disposeConverter()
        if let drainError { throw drainError }
        guard status == noErr else { throw ScribeError.writeFailed(status) }
    }

    deinit {
        try? close()
        disposeConverter()
    }
}
