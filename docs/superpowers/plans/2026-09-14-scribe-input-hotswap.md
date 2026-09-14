# Input Device Hot-Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the default input device changes mid-recording, rebuild the capture graph around the new microphone and keep writing to the same WAV file instead of stopping the recording.

**Architecture:** The `ProcessTap` and `WavWriter` outlive a swap; only the aggregate device and its IO proc are rebuilt. That rebuildable pair moves behind an `InputGraph` protocol so the swap policy can be unit tested against a fake. Because `ExtAudioFile` refuses a client-format change once written, `WavWriter` pins its file client format at 48 kHz and owns an `AudioConverterRef` that absorbs whatever rate the current mic delivers.

**Tech Stack:** Swift 6, SwiftPM (no Xcode project), Core Audio / AudioToolbox (`AudioConverterRef`, `ExtAudioFile`, aggregate devices, process taps), Swift Testing, SwiftUI `MenuBarExtra`.

**Spec:** `docs/superpowers/specs/2026-09-14-scribe-input-hotswap-design.md`

## Global Constraints

- **Minimum macOS 14.2.** Dev machine runs macOS 26.6.2, Swift 6.3.2.
- **Run tests with `scripts/test.sh`, never bare `swift test`.** This machine is Command Line Tools only; SwiftPM does not add Testing.framework's search path or rpath by itself. The wrapper forwards arguments: `scripts/test.sh --filter WavWriterTests`.
- **Swift Testing, not XCTest.** CLT ships Swift Testing. Use `@Suite`, `@Test`, `#expect`, `#require`.
- **Output format is fixed:** one stereo WAV per recording, 48 kHz, 16-bit PCM, left = mic, right = system audio. Nothing in this plan changes it.
- **Every failure path during a swap falls back to today's behavior:** stop, keep the partial file, notify. A broken swap must never be worse than the current stop-on-change.
- **No new dependencies.** SwiftPM targets stay as they are.
- **Unit tests must not need audio hardware, a microphone, or TCC permissions.** `WavWriter` can be constructed on a temp file with no permissions; `ProcessTap` and `AggregateDevice` cannot be, which is why the swap policy is extracted away from them.
- **`AudioConverterFillComplexBuffer` runs on the real-time audio thread.** No allocation, no locks, no Swift runtime calls that can allocate inside `writeAsync`.

---

## File Structure

**Create:**
- `Sources/ScribeCore/CaptureGraph.swift` — the `InputGraph` / `InputGraphBuilding` protocols, the live implementation (`LiveInputGraph`), and its builder. One mic generation's worth of capture.
- `Sources/ScribeCore/InputSwapController.swift` — the swap policy: filter, coalesce, stop/rebuild/retune/start, failure fallback, cancellation. Holds no Core Audio objects of its own, so it is fully unit testable.
- `Tests/ScribeCoreTests/InputSwapTests.swift` — fake-driven tests for the controller.

**Modify:**
- `Sources/ScribeCore/WavWriter.swift` — fixed 48 kHz client format, internal `AudioConverterRef`, `setInputSampleRate(_:)`.
- `Sources/ScribeCore/AggregateDevice.swift` — expose `micDeviceID` so the swap filter can compare devices.
- `Sources/ScribeCore/LiveCapture.swift` — own the tap/writer/keepalive/watchers, delegate the graph to `InputSwapController`; `AudioCapturing` gains `micName` and `onInputChanged`.
- `Sources/ScribeCore/RecordingSession.swift` — observable `micName`.
- `Sources/Scribe/AppState.swift`, `Sources/Scribe/MenuView.swift` — show the live mic name.
- `Tests/ScribeCoreTests/WavWriterTests.swift`, `Tests/ScribeCoreTests/RecordingSessionTests.swift` — extended.
- `docs/smoke-test.md` — swap checks added, hot-swap known-gap entry removed.

`CaptureEngine.swift`, `IOState`, `Downmix.swift`, `ProcessTap.swift`, `OutputKeepAlive.swift` and `StereoBuffer.swift` are **not** modified.

---

### Task 1: WavWriter owns the sample rate conversion

The writer currently hands `inputSampleRate` to `ExtAudioFile` as its client format and lets it resample. The spike proved that property cannot change once written, so the writer takes ownership of the conversion. This task changes the mechanism without changing any observable behavior — the same inputs still produce the same files.

**Files:**
- Modify: `Sources/ScribeCore/WavWriter.swift`
- Test: `Tests/ScribeCoreTests/WavWriterTests.swift`

**Interfaces:**
- Consumes: `StereoBuffer` (existing), `ScribeError.writeFailed(OSStatus)` (existing).
- Produces: `WavWriter.init(url:inputSampleRate:maxInputFrames:)` with `maxInputFrames: Int = 8192`; `public private(set) var inputSampleRate: Double`. `prime()`, `writeAsync(frames:_:)`, `write(frames:_:)`, `close()` keep their existing signatures.

- [ ] **Step 1: Write the failing test for 24 kHz input**

Add to `Tests/ScribeCoreTests/WavWriterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `scripts/test.sh --filter WavWriterTests`

Expected: FAIL. Today the client format is set to 24 kHz and `ExtAudioFile` resamples internally, so this test may actually pass by accident. **If it passes, that is fine and expected** — it is a characterization test that must keep passing after the mechanism changes. Confirm the whole suite is green before continuing, and treat Step 6 as the real gate.

- [ ] **Step 3: Pin the client format and add the converter**

Replace the top of `Sources/ScribeCore/WavWriter.swift` through `init` with:

```swift
import AudioToolbox
import CoreAudio
import Foundation

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
            try makeConverter()
        } catch {
            ExtAudioFileDispose(created)
            self.file = nil
            throw error
        }
    }
```

- [ ] **Step 4: Add the converter lifecycle and the input callback**

Insert after `init` in the same file:

```swift
    /// Supplies the whole input block to the converter once, then reports
    /// exhaustion. A C function pointer, so it captures nothing; the block
    /// travels through `inUserData`.
    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
        guard let raw = inUserData else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let ctx = raw.assumingMemoryBound(to: ConverterInput.self)
        if ctx.pointee.consumed {
            ioNumberDataPackets.pointee = 0
            return noErr
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

    /// No converter at 48 kHz in: input passes straight through.
    private func makeConverter() throws {
        disposeConverter()
        guard inputSampleRate != Self.fileSampleRate else { return }

        var inFormat = Self.floatFormat(rate: inputSampleRate)
        var outFormat = Self.floatFormat(rate: Self.fileSampleRate)
        var ref: AudioConverterRef?
        let status = AudioConverterNew(&inFormat, &outFormat, &ref)
        guard status == noErr, let ref else { throw ScribeError.writeFailed(status) }
        converter = ref

        // Upsampling produces more frames than it consumes, so the output
        // buffer is sized for the worst case plus slack for filter latency.
        let ratio = Self.fileSampleRate / inputSampleRate
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
        guard status == noErr else { return status }
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
```

- [ ] **Step 5: Route the write methods through the converter**

Replace the existing `prime()`, `writeAsync(frames:_:)`, `write(frames:_:)` and `deinit` bodies:

```swift
    /// Call once from a non-real-time thread before the first `writeAsync`.
    public func prime() throws {
        guard let file else { throw ScribeError.writeFailed(kAudioFileNotOpenError) }
        primeConverter()
        let status = ExtAudioFileWriteAsync(file, 0, nil)
        guard status == noErr else { throw ScribeError.writeFailed(status) }
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
```

and add the converter teardown to `close()` and `deinit`:

```swift
    /// Flushes pending async writes and finalizes the header. Idempotent.
    ///
    /// Not safe to call concurrently with `writeAsync`: stop the IO proc first
    /// (`CaptureEngine.stop()`, which is synchronous). See the type's doc
    /// comment for the full contract.
    public func close() throws {
        guard let file else { return }
        self.file = nil
        let status = ExtAudioFileDispose(file)
        disposeConverter()
        guard status == noErr else { throw ScribeError.writeFailed(status) }
    }

    deinit {
        try? close()
        disposeConverter()
    }
```

- [ ] **Step 6: Run the whole suite**

Run: `scripts/test.sh`

Expected: PASS, all suites. `resamples24kInputTo48kFile` passes, and every pre-existing `WavWriterTests` case still passes — those exercise the 48 kHz passthrough path, which must be byte-identical to before.

- [ ] **Step 7: Add the chunked async-path test**

The spike's open caveat was that it never proved conversion works feeding `ExtAudioFileWriteAsync` in realistic chunks. Add to `Tests/ScribeCoreTests/WavWriterTests.swift`:

```swift
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
```

- [ ] **Step 8: Run it**

Run: `scripts/test.sh --filter WavWriterTests`

Expected: PASS. If the frame count is outside the margin, print `file.length` and check whether `primeConverter`'s discarded silence block is being counted — it must not be, because its output is dropped.

- [ ] **Step 9: Commit**

```bash
git add Sources/ScribeCore/WavWriter.swift Tests/ScribeCoreTests/WavWriterTests.swift
git commit -m "WavWriter owns sample rate conversion instead of ExtAudioFile

The file's client format is now pinned at 48 kHz and an AudioConverterRef
absorbs the input rate, because kExtAudioFileProperty_ClientDataFormat
cannot be changed once audio has been written. At 48 kHz in there is no
converter and input passes straight through, so existing behavior is
unchanged.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: WavWriter.setInputSampleRate

Task 1 made the conversion ours. This makes it changeable mid-file, which is what a swap between a 24 kHz mic and a 48 kHz one needs.

**Files:**
- Modify: `Sources/ScribeCore/WavWriter.swift`
- Test: `Tests/ScribeCoreTests/WavWriterTests.swift`

**Interfaces:**
- Consumes: `makeConverter()`, `primeConverter()`, `inputSampleRate` from Task 1.
- Produces: `public func setInputSampleRate(_ rate: Double) throws`. Callers: `InputSwapController` in Task 4.

- [ ] **Step 1: Write the failing test**

Add to `Tests/ScribeCoreTests/WavWriterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test.sh --filter WavWriterTests`

Expected: FAIL to compile — "value of type 'WavWriter' has no member 'setInputSampleRate'".

- [ ] **Step 3: Implement it**

Add to `Sources/ScribeCore/WavWriter.swift`, after `prime()`:

```swift
    /// Rebuilds the internal converter for a new input rate, mid-file.
    ///
    /// Same precondition as `close()`: the caller must have stopped the IO proc
    /// first. `writeAsync` reads `converter` without a lock, so changing it
    /// under a running proc is a use-after-free.
    public func setInputSampleRate(_ rate: Double) throws {
        guard rate > 0 else { throw ScribeError.writeFailed(kAudio_ParamError) }
        guard rate != inputSampleRate else { return }
        inputSampleRate = rate
        try makeConverter()
        primeConverter()
    }
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh --filter WavWriterTests`

Expected: PASS, both new cases and all pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScribeCore/WavWriter.swift Tests/ScribeCoreTests/WavWriterTests.swift
git commit -m "Let WavWriter change its input sample rate mid-file

Rebuilds the internal converter. Carries the same stop-the-IO-proc-first
precondition as close().

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Extract the rebuildable graph and the swap controller

Pure restructuring, no behavior change. `LiveCapture` currently owns the aggregate and engine directly, which makes the swap untestable: its `init` creates a real `ProcessTap`, so nothing about it can run without System Audio permission. Extracting the graph behind a protocol and the policy into `InputSwapController` — which holds no Core Audio objects of its own — is what makes Task 4 testable.

**Files:**
- Create: `Sources/ScribeCore/CaptureGraph.swift`
- Create: `Sources/ScribeCore/InputSwapController.swift`
- Create: `Tests/ScribeCoreTests/InputSwapTests.swift`
- Modify: `Sources/ScribeCore/AggregateDevice.swift:11-21`
- Modify: `Sources/ScribeCore/LiveCapture.swift`

**Interfaces:**
- Consumes: `AggregateDevice`, `CaptureEngine`, `ProcessTap`, `WavWriter`, `InterruptionRelay`, `OutputKeepAlive`, `DefaultDeviceWatcher`, `CoreAudio.defaultInputDevice()` — all existing.
- Produces:
  - `protocol InputGraph: AnyObject { var micDeviceID: AudioDeviceID { get }; var micName: String { get }; var sampleRate: Double { get }; func start() throws; func stop() }`
  - `protocol InputGraphBuilding { func makeGraph() throws -> any InputGraph }`
  - `final class LiveInputGraph: InputGraph`, `struct LiveInputGraphBuilder: InputGraphBuilding`
  - `@MainActor final class InputSwapController` with `init(builder:writer:coalesceWindow:currentInputDevice:)`, `var onInputChanged: ((String) -> Void)?`, `var onFailure: ((ScribeError) -> Void)?`, `private(set) var micName: String`, `func start() throws`, `func stop()`.
  - `AggregateDevice.micDeviceID: AudioDeviceID`

- [ ] **Step 1: Expose the mic's device ID on the aggregate**

The swap filter compares the current default input against the device the graph is already on, so the graph has to know which device that was. In `Sources/ScribeCore/AggregateDevice.swift`, add the stored property beside `micName` and assign it in `init`:

```swift
public final class AggregateDevice {
    public let deviceID: AudioDeviceID
    public let layout: InputLayout
    public let sampleRate: Double
    public let micName: String
    public let micDeviceID: AudioDeviceID
    private let tap: ProcessTap

    public init(tap: ProcessTap) throws {
        self.tap = tap
        let mic = try CoreAudio.defaultInputDevice()
        let micUID = try CoreAudio.uid(of: mic)
        let micStreams = try CoreAudio.inputStreamChannelCounts(of: mic)
        micName = CoreAudio.name(of: mic)
        micDeviceID = mic
```

Everything below that line in `init` is unchanged.

- [ ] **Step 2: Create the graph protocols and the live implementation**

Create `Sources/ScribeCore/CaptureGraph.swift`:

```swift
import CoreAudio
import Foundation

/// One microphone generation's worth of capture: an aggregate device built
/// around the current default input, plus the IO proc driving it. Rebuilt on
/// every input device swap. The tap and writer it feeds outlive it.
protocol InputGraph: AnyObject {
    /// The default input device this graph was built around. The swap policy
    /// compares it against the current default to ignore no-op notifications.
    var micDeviceID: AudioDeviceID { get }
    var micName: String { get }
    var sampleRate: Double { get }
    func start() throws
    func stop()
}

protocol InputGraphBuilding {
    /// Builds a graph around whatever the default input device is right now.
    func makeGraph() throws -> any InputGraph
}

/// The real thing: aggregate + engine, built from a tap and writer it does not
/// own. Releasing the aggregate destroys it; the tap survives for the next
/// graph, which is why a swap never re-creates the tap or re-prompts for the
/// System Audio permission.
final class LiveInputGraph: InputGraph {
    let micDeviceID: AudioDeviceID
    let micName: String
    let sampleRate: Double
    private var aggregate: AggregateDevice?
    private let engine: CaptureEngine

    init(tap: ProcessTap, writer: WavWriter, relay: InterruptionRelay) throws {
        let aggregate = try AggregateDevice(tap: tap)
        self.aggregate = aggregate
        micDeviceID = aggregate.micDeviceID
        micName = aggregate.micName
        sampleRate = aggregate.sampleRate
        engine = CaptureEngine(
            deviceID: aggregate.deviceID, layout: aggregate.layout,
            writer: writer, relay: relay)
    }

    func start() throws {
        try engine.start()
    }

    /// Engine first, then the aggregate: `CaptureEngine.stop()` is synchronous,
    /// so no IO proc is running by the time the device goes away.
    func stop() {
        engine.stop()
        aggregate = nil
    }

    deinit {
        stop()
    }
}

struct LiveInputGraphBuilder: InputGraphBuilding {
    let tap: ProcessTap
    let writer: WavWriter
    let relay: InterruptionRelay

    func makeGraph() throws -> any InputGraph {
        try LiveInputGraph(tap: tap, writer: writer, relay: relay)
    }
}
```

- [ ] **Step 3: Create the controller with start and stop only**

No swapping yet — that is Task 4. Create `Sources/ScribeCore/InputSwapController.swift`:

```swift
import CoreAudio
import Foundation

/// Owns the current `InputGraph` and, from Task 4, the policy for replacing it
/// when the default input device changes.
///
/// Main-actor isolated: `DefaultDeviceWatcher` delivers on the main queue and
/// every mutation here happens in response to one, so no locking is needed.
/// It deliberately holds no Core Audio objects of its own — the tap and writer
/// belong to `LiveCapture` — which is what lets it be tested with a fake
/// builder and no audio hardware.
@MainActor
final class InputSwapController {
    /// Called with the new mic's name after a successful swap.
    var onInputChanged: ((String) -> Void)?
    /// Called when the recording cannot continue. Routed to the interruption
    /// relay by `LiveCapture`, which stops and saves the partial file.
    var onFailure: ((ScribeError) -> Void)?

    private(set) var micName = ""

    private let builder: any InputGraphBuilding
    private let writer: WavWriter
    private let coalesceWindow: TimeInterval
    private let currentInputDevice: () throws -> AudioDeviceID
    private var graph: (any InputGraph)?

    init(builder: any InputGraphBuilding,
         writer: WavWriter,
         coalesceWindow: TimeInterval = 0.3,
         currentInputDevice: @escaping () throws -> AudioDeviceID = CoreAudio.defaultInputDevice) {
        self.builder = builder
        self.writer = writer
        self.coalesceWindow = coalesceWindow
        self.currentInputDevice = currentInputDevice
    }

    func start() throws {
        guard graph == nil else { return }
        let graph = try builder.makeGraph()
        try graph.start()
        self.graph = graph
        micName = graph.micName
    }

    func stop() {
        graph?.stop()
        graph = nil
    }
}
```

- [ ] **Step 4: Write the controller's start/stop tests**

Create `Tests/ScribeCoreTests/InputSwapTests.swift`:

```swift
import CoreAudio
import Foundation
import Testing

@testable import ScribeCore

final class FakeInputGraph: InputGraph {
    let micDeviceID: AudioDeviceID
    let micName: String
    let sampleRate: Double
    var started = false
    var stopped = false
    var startError: ScribeError?

    init(micDeviceID: AudioDeviceID, micName: String, sampleRate: Double = 48_000) {
        self.micDeviceID = micDeviceID
        self.micName = micName
        self.sampleRate = sampleRate
    }

    func start() throws {
        if let startError { throw startError }
        started = true
    }

    func stop() {
        stopped = true
    }
}

/// Hands out a queued sequence of graphs, recording how many were asked for.
final class FakeGraphBuilder: InputGraphBuilding {
    var queue: [FakeInputGraph] = []
    var built: [FakeInputGraph] = []
    var makeError: ScribeError?

    func makeGraph() throws -> any InputGraph {
        if let makeError { throw makeError }
        let graph = queue.isEmpty
            ? FakeInputGraph(micDeviceID: 1, micName: "Fallback")
            : queue.removeFirst()
        built.append(graph)
        return graph
    }
}

@MainActor
@Suite struct InputSwapTests {
    private func tempWriter() throws -> (WavWriter, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-swap-\(UUID().uuidString).wav")
        return (try WavWriter(url: url, inputSampleRate: 48_000), url)
    }

    @Test func startBuildsAndStartsAGraph() throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        let controller = InputSwapController(
            builder: builder, writer: writer, coalesceWindow: 0.01,
            currentInputDevice: { 7 })

        try controller.start()

        #expect(builder.built.count == 1)
        #expect(builder.built[0].started)
        #expect(controller.micName == "AirPods")
    }

    @Test func stopStopsTheGraph() throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        let controller = InputSwapController(
            builder: builder, writer: writer, coalesceWindow: 0.01,
            currentInputDevice: { 7 })

        try controller.start()
        controller.stop()

        #expect(builder.built[0].stopped)
    }
}
```

- [ ] **Step 5: Run them**

Run: `scripts/test.sh --filter InputSwapTests`

Expected: PASS, 2 tests.

- [ ] **Step 6: Rewire LiveCapture onto the controller**

Replace the body of `Sources/ScribeCore/LiveCapture.swift` below the protocol declarations. The protocols at the top of the file (`AudioCapturing`, `CaptureFactory`) are unchanged in this task; Task 5 extends them.

```swift
/// The real thing: tap + writer + keepalive for one file, with the swappable
/// aggregate and engine delegated to `InputSwapController`.
/// Teardown order matters: watchers, controller, keepalive, writer, then tap.
final class LiveCapture: AudioCapturing {
    private var tap: ProcessTap?
    private let writer: WavWriter
    private let controller: InputSwapController
    private let relay = InterruptionRelay()
    private let keepAlive = OutputKeepAlive()
    private var inputWatcher: DefaultDeviceWatcher?
    private let outputWatcher: DefaultDeviceWatcher

    var onInterrupted: (@Sendable (ScribeError) -> Void)? {
        didSet { relay.handler = onInterrupted }
    }

    init(url: URL) throws {
        let tap = try ProcessTap()
        // The writer's rate is a placeholder until the first graph reports the
        // real one; `InputSwapController.start()` retunes it before any audio
        // is written.
        let writer = try WavWriter(url: url, inputSampleRate: WavWriter.fileSampleRate)
        self.tap = tap
        self.writer = writer

        let relay = self.relay
        self.controller = InputSwapController(
            builder: LiveInputGraphBuilder(tap: tap, writer: writer, relay: relay),
            writer: writer)

        // Captures the objects it uses, not `self`, which is not fully
        // initialized here. See the phase 1 note: the keepalive is pinned to
        // the output device it started on, so a new default output would stall
        // the aggregate. Restarting it moves the silent IO proc to the new
        // device. Output-device changes are not interruptions, so a successful
        // restart keeps the relay quiet; a keepalive that cannot re-arm means
        // the aggregate has lost its clock, so that case is reported and the
        // recording stops.
        let keepAlive = self.keepAlive
        self.outputWatcher = .defaultOutput { [weak keepAlive] in
            guard let keepAlive else { return }
            keepAlive.stop()
            do {
                try keepAlive.start()
            } catch let error as ScribeError {
                relay.fire(error)
            } catch {
                relay.fire(.captureStartFailed(-1))
            }
        }

        MainActor.assumeIsolated {
            controller.onFailure = { [weak relay] error in relay?.fire(error) }
        }
    }

    func start() throws {
        try keepAlive.start()
        try MainActor.assumeIsolated { try controller.start() }
        try outputWatcher.start()
    }

    func stop() throws {
        inputWatcher?.stop()
        inputWatcher = nil
        outputWatcher.stop()
        MainActor.assumeIsolated { controller.stop() }
        keepAlive.stop()
        defer { tap = nil }
        try writer.close()
    }

    deinit {
        inputWatcher?.stop()
        outputWatcher.stop()
        MainActor.assumeIsolated { controller.stop() }
        keepAlive.stop()
        try? writer.close()
        tap = nil
    }
}

public struct LiveCaptureFactory: CaptureFactory {
    public init() {}

    public func makeCapture(url: URL) throws -> any AudioCapturing {
        try LiveCapture(url: url)
    }
}
```

Note: `inputWatcher` is deliberately not created yet. Task 4 creates it in `start()`, where `self` is fully initialized and the closure can call back into the controller.

The writer is now constructed at 48 kHz rather than the aggregate's rate, because the aggregate no longer exists at that point. `InputSwapController.start()` gains the retune call in Task 4; until then a non-48 kHz mic would be written at the wrong rate. **This task is not shippable on its own** — it must land together with Task 4, which is why both are committed before any manual check.

- [ ] **Step 7: Run the whole suite**

Run: `scripts/test.sh`

Expected: PASS, all suites, including the untouched `RecordingSessionTests`. If `MainActor.assumeIsolated` produces a Swift 6 isolation error in `init`, move the `controller.onFailure` assignment into `start()` alongside the other main-actor work.

- [ ] **Step 8: Commit**

```bash
git add Sources/ScribeCore/CaptureGraph.swift Sources/ScribeCore/InputSwapController.swift \
        Sources/ScribeCore/AggregateDevice.swift Sources/ScribeCore/LiveCapture.swift \
        Tests/ScribeCoreTests/InputSwapTests.swift
git commit -m "Extract the rebuildable capture graph behind a protocol

LiveCapture's init creates a real ProcessTap, so nothing about it could be
tested without System Audio permission. The aggregate and engine now sit
behind InputGraph, and the policy that owns them lives in
InputSwapController, which holds no Core Audio objects and can be driven
by a fake builder. No behavior change yet.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The swap policy

The feature itself. With the controller testable, this is where the default-input watcher stops ending the recording and starts rebuilding the graph.

**Files:**
- Modify: `Sources/ScribeCore/InputSwapController.swift`
- Modify: `Sources/ScribeCore/LiveCapture.swift`
- Test: `Tests/ScribeCoreTests/InputSwapTests.swift`

**Interfaces:**
- Consumes: everything Task 3 produced, plus `WavWriter.setInputSampleRate(_:)` from Task 2.
- Produces: `InputSwapController.handleInputChange()`, called from `LiveCapture`'s input watcher.

- [ ] **Step 1: Write the failing tests**

Add to the `InputSwapTests` suite in `Tests/ScribeCoreTests/InputSwapTests.swift`:

```swift
    /// Helper: a controller wired to `builder` whose reported default input
    /// device can be changed by the test.
    private func makeController(_ builder: FakeGraphBuilder,
                                _ writer: WavWriter,
                                device: @escaping () -> AudioDeviceID)
        -> InputSwapController {
        InputSwapController(builder: builder, writer: writer,
                            coalesceWindow: 0.01, currentInputDevice: { device() })
    }

    @Test func rebuildsTheGraphWhenTheDefaultInputChanges() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [
            FakeInputGraph(micDeviceID: 7, micName: "AirPods"),
            FakeInputGraph(micDeviceID: 9, micName: "MacBook Pro Microphone"),
        ]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })
        var announced: [String] = []
        controller.onInputChanged = { announced.append($0) }

        try controller.start()
        device = 9
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(builder.built.count == 2)
        #expect(builder.built[0].stopped)
        #expect(builder.built[1].started)
        #expect(controller.micName == "MacBook Pro Microphone")
        #expect(announced == ["MacBook Pro Microphone"])
    }

    @Test func ignoresAChangeThatResolvesToTheSameDevice() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        let controller = makeController(builder, writer, device: { 7 })

        try controller.start()
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(builder.built.count == 1)
        #expect(!builder.built[0].stopped)
    }

    @Test func coalescesABurstIntoOneRebuild() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [
            FakeInputGraph(micDeviceID: 7, micName: "AirPods"),
            FakeInputGraph(micDeviceID: 9, micName: "MacBook Pro Microphone"),
        ]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })

        try controller.start()
        device = 9
        controller.handleInputChange()
        controller.handleInputChange()
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(builder.built.count == 2)
    }

    @Test func retunesTheWriterOnlyWhenTheRateChanges() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [
            FakeInputGraph(micDeviceID: 7, micName: "AirPods", sampleRate: 24_000),
            FakeInputGraph(micDeviceID: 9, micName: "Built-in", sampleRate: 48_000),
        ]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })

        try controller.start()
        #expect(writer.inputSampleRate == 24_000)

        device = 9
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(writer.inputSampleRate == 48_000)
    }

    @Test func aBuilderFailureReportsOneInterruption() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })
        var failures: [ScribeError] = []
        controller.onFailure = { failures.append($0) }

        try controller.start()
        builder.makeError = .aggregateCreationFailed(-1)
        device = 9
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(failures == [.aggregateCreationFailed(-1)])
    }

    @Test func aStartFailureOnTheNewGraphReportsOneInterruption() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        let replacement = FakeInputGraph(micDeviceID: 9, micName: "Built-in")
        replacement.startError = .captureStartFailed(-2)
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods"), replacement]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })
        var failures: [ScribeError] = []
        controller.onFailure = { failures.append($0) }

        try controller.start()
        device = 9
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(failures == [.captureStartFailed(-2)])
    }

    @Test func aVanishedInputDeviceReportsInputDeviceChanged() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        var present = true
        let controller = InputSwapController(
            builder: builder, writer: writer, coalesceWindow: 0.01,
            currentInputDevice: {
                if present { return 7 }
                throw ScribeError.noInputDevice
            })
        var failures: [ScribeError] = []
        controller.onFailure = { failures.append($0) }

        try controller.start()
        present = false
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(failures == [.inputDeviceChanged])
    }

    @Test func stopCancelsAPendingSwap() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [
            FakeInputGraph(micDeviceID: 7, micName: "AirPods"),
            FakeInputGraph(micDeviceID: 9, micName: "Built-in"),
        ]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })

        try controller.start()
        device = 9
        controller.handleInputChange()
        controller.stop()
        try writer.close()
        try await Task.sleep(for: .milliseconds(80))

        // No second graph was built, and nothing touched the closed writer.
        #expect(builder.built.count == 1)
    }
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test.sh --filter InputSwapTests`

Expected: FAIL to compile — "value of type 'InputSwapController' has no member 'handleInputChange'".

- [ ] **Step 3: Implement the policy**

In `Sources/ScribeCore/InputSwapController.swift`, add `pendingSwap` to the stored properties:

```swift
    private var graph: (any InputGraph)?
    private var pendingSwap: DispatchWorkItem?
```

retune the writer in `start()`:

```swift
    func start() throws {
        guard graph == nil else { return }
        let graph = try builder.makeGraph()
        try writer.setInputSampleRate(graph.sampleRate)
        try graph.start()
        self.graph = graph
        micName = graph.micName
    }
```

cancel pending work in `stop()`:

```swift
    func stop() {
        pendingSwap?.cancel()
        pendingSwap = nil
        graph?.stop()
        graph = nil
    }
```

and add the policy itself:

```swift
    /// Called from the default-input watcher on the main queue.
    ///
    /// The watcher fires on any change to the property, including ones that
    /// resolve back to the device we are already on, so the cheap filter runs
    /// first and the device is re-resolved again after the window.
    func handleInputChange() {
        guard let graph, pendingSwap == nil else { return }
        guard let current = try? currentInputDevice() else {
            // The last input device is gone with no replacement. Nothing to
            // swap to, so fall back to phase 1 behavior.
            onFailure?(.inputDeviceChanged)
            return
        }
        guard current != graph.micDeviceID else { return }

        // The window is fixed from the first notification and is deliberately
        // not extended by later ones: a device that flaps continuously would
        // otherwise postpone the swap indefinitely, leaving the recording on a
        // mic that is already gone.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSwap = nil
                self.performSwap()
            }
        }
        pendingSwap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceWindow, execute: work)
    }

    /// Stop, rebuild, retune, start. Any failure falls back to stop-and-save,
    /// which is never worse than phase 1's stop-on-change.
    private func performSwap() {
        guard let old = graph else { return }
        guard let current = try? currentInputDevice() else {
            onFailure?(.inputDeviceChanged)
            return
        }
        guard current != old.micDeviceID else { return }

        // Synchronous, so no `writeAsync` is in flight once it returns — which
        // is what makes `setInputSampleRate` safe below.
        old.stop()
        graph = nil

        do {
            let next = try builder.makeGraph()
            try writer.setInputSampleRate(next.sampleRate)
            try next.start()
            graph = next
            micName = next.micName
            onInputChanged?(next.micName)
        } catch let error as ScribeError {
            onFailure?(error)
        } catch {
            onFailure?(.captureStartFailed(-1))
        }
    }
```

- [ ] **Step 4: Run the tests**

Run: `scripts/test.sh --filter InputSwapTests`

Expected: PASS, 10 tests.

- [ ] **Step 5: Wire the watcher up in LiveCapture**

The input watcher currently ends the recording. In `Sources/ScribeCore/LiveCapture.swift`, replace `start()` so it creates the watcher there — `self` is fully initialized by then, so the closure can call into the controller:

```swift
    func start() throws {
        try keepAlive.start()
        try MainActor.assumeIsolated { try controller.start() }

        // Created here rather than in `init` so the closure can reach the
        // controller. Delivers on the main queue, which is where the
        // controller expects to be called.
        let controller = self.controller
        let watcher = DefaultDeviceWatcher.defaultInput {
            MainActor.assumeIsolated { controller.handleInputChange() }
        }
        try watcher.start()
        inputWatcher = watcher

        try outputWatcher.start()
    }
```

- [ ] **Step 6: Run the whole suite**

Run: `scripts/test.sh`

Expected: PASS, all suites.

- [ ] **Step 7: Build the app and check it launches**

```bash
scripts/bundle.sh
```

Expected: the app builds, signs and launches; the menu bar icon appears. This only confirms nothing broke at the integration level — the real swap check is the smoke test in Task 6.

- [ ] **Step 8: Commit**

```bash
git add Sources/ScribeCore/InputSwapController.swift Sources/ScribeCore/LiveCapture.swift \
        Tests/ScribeCoreTests/InputSwapTests.swift
git commit -m "Continue recording across an input device change

The default-input watcher now rebuilds the capture graph around the new
mic instead of ending the recording: filter no-op notifications, coalesce
bursts into one rebuild, stop the old graph, retune the writer when the
rate changes, start the new one. Every failure path still falls back to
stop-and-save.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Show the live mic name in the menu

A swap is silent by design, so the only way to tell which mic a recording is using is to surface it.

**Files:**
- Modify: `Sources/ScribeCore/LiveCapture.swift` (the `AudioCapturing` protocol and `LiveCapture`)
- Modify: `Sources/ScribeCore/RecordingSession.swift`
- Modify: `Sources/Scribe/AppState.swift`
- Modify: `Sources/Scribe/MenuView.swift:16-21`
- Test: `Tests/ScribeCoreTests/RecordingSessionTests.swift`

**Interfaces:**
- Consumes: `InputSwapController.onInputChanged` and `micName` from Tasks 3-4.
- Produces: `AudioCapturing.micName: String`, `AudioCapturing.onInputChanged: (@Sendable (String) -> Void)?`, `RecordingSession.micName: String?`, `AppState.micName: String?`.

- [ ] **Step 1: Write the failing tests**

In `Tests/ScribeCoreTests/RecordingSessionTests.swift`, first extend `FakeCapture` to satisfy the widened protocol:

```swift
final class FakeCapture: AudioCapturing {
    var onInterrupted: (@Sendable (ScribeError) -> Void)?
    var onInputChanged: (@Sendable (String) -> Void)?
    var micName = "Fake Microphone"
    var started = false
    var stopped = false
    var startError: ScribeError?
    /// Set by `FakeFactory`, so a failing `start()` can leave a real file
    /// behind the way the live capture would.
    var url: URL?

    func start() throws {
        if let startError {
            if let url { try? Data().write(to: url) }
            throw startError
        }
        started = true
    }

    func stop() throws {
        stopped = true
    }
}
```

then add to the `RecordingSessionTests` suite:

```swift
    @Test func publishesTheMicNameWhileRecording() throws {
        let (session, factory, _) = makeSession()
        factory.capture.micName = "AirPods"

        try session.start()

        #expect(session.micName == "AirPods")
    }

    @Test func updatesTheMicNameOnSwap() throws {
        let (session, factory, _) = makeSession()
        factory.capture.micName = "AirPods"
        try session.start()

        factory.capture.onInputChanged?("MacBook Pro Microphone")

        #expect(session.micName == "MacBook Pro Microphone")
        #expect(session.isRecording)
    }

    @Test func clearsTheMicNameOnStop() throws {
        let (session, factory, _) = makeSession()
        factory.capture.micName = "AirPods"
        try session.start()

        _ = try session.stop()

        #expect(session.micName == nil)
    }

    @Test func clearsTheMicNameWhenASwapFails() throws {
        let (session, factory, _) = makeSession()
        factory.capture.micName = "AirPods"
        try session.start()

        // A swap that cannot complete reports through the same interruption
        // path as any other failure.
        factory.capture.onInterrupted?(.aggregateCreationFailed(-1))

        #expect(session.micName == nil)
        #expect(session.state == .idle)
    }
```

The spec also calls for "a failed swap leaves the session `.idle` and calls
`onInterrupted` once". That is already covered by the existing
`interruptionStopsAndReports` and `interruptionAfterStopIsIgnored` cases — a
failed swap reaches `RecordingSession` through exactly the same
`capture.onInterrupted` callback, so no new test is needed for it. Do not delete
those two cases.

- [ ] **Step 2: Run them to make sure they fail**

Run: `scripts/test.sh --filter RecordingSessionTests`

Expected: FAIL to compile — "value of type 'RecordingSession' has no member 'micName'".

- [ ] **Step 3: Widen the AudioCapturing protocol**

In `Sources/ScribeCore/LiveCapture.swift`:

```swift
/// One recording's worth of audio capture. `onInterrupted` is called on the
/// main thread when capture stops for a reason other than `stop()`.
/// `onInputChanged` is called on the main thread with the new microphone's name
/// after the capture has swapped to a different input device.
public protocol AudioCapturing: AnyObject {
    var onInterrupted: (@Sendable (ScribeError) -> Void)? { get set }
    var onInputChanged: (@Sendable (String) -> Void)? { get set }
    /// The microphone being recorded right now.
    var micName: String { get }
    func start() throws
    func stop() throws
}
```

- [ ] **Step 4: Implement it on LiveCapture**

Add to `LiveCapture`, beside `onInterrupted`:

```swift
    var onInputChanged: (@Sendable (String) -> Void)? {
        didSet {
            let handler = onInputChanged
            MainActor.assumeIsolated {
                controller.onInputChanged = { name in handler?(name) }
            }
        }
    }

    var micName: String {
        MainActor.assumeIsolated { controller.micName }
    }
```

- [ ] **Step 5: Publish it from RecordingSession**

In `Sources/ScribeCore/RecordingSession.swift`, add the property beside `state`:

```swift
    public private(set) var state: State = .idle
    /// The microphone currently being recorded, or nil when idle.
    public private(set) var micName: String?
```

set it in `start()`, right after `capture.onInterrupted` is wired:

```swift
            capture.onInterrupted = { [weak self] error in
                MainActor.assumeIsolated {
                    self?.handleInterruption(error)
                }
            }
            capture.onInputChanged = { [weak self] name in
                MainActor.assumeIsolated {
                    self?.micName = name
                }
            }
            try capture.start()
```

then after `self.capture = made`:

```swift
        self.capture = made
        micName = made?.micName
        state = .recording(since: now, url: url)
        return url
```

and clear it in `stop()`:

```swift
        state = .finalizing
        self.capture = nil
        micName = nil
        defer { state = .idle }
```

- [ ] **Step 6: Run the tests**

Run: `scripts/test.sh --filter RecordingSessionTests`

Expected: PASS, including all pre-existing cases.

- [ ] **Step 7: Surface it in the menu**

In `Sources/Scribe/AppState.swift`, add beside `isRecording`:

```swift
    var isRecording: Bool { session.isRecording }
    var micName: String? { session.micName }
    var recordingsDirectory: URL { session.store.directory }
```

In `Sources/Scribe/MenuView.swift`, add the mic line under the timer:

```swift
        if state.isRecording {
            Button("Stop Recording") { state.toggle() }
            Text("Recording  \(state.elapsedText)")
            if let micName = state.micName {
                Text(micName)
            }
        } else {
            Button("Start Recording") { state.toggle() }
        }
```

- [ ] **Step 8: Run the whole suite and build**

```bash
scripts/test.sh
scripts/bundle.sh
```

Expected: tests PASS. The app launches; Start Recording, then open the menu and confirm the current microphone's name appears under the elapsed time.

- [ ] **Step 9: Commit**

```bash
git add Sources/ScribeCore/LiveCapture.swift Sources/ScribeCore/RecordingSession.swift \
        Sources/Scribe/AppState.swift Sources/Scribe/MenuView.swift \
        Tests/ScribeCoreTests/RecordingSessionTests.swift
git commit -m "Show the microphone being recorded in the menu

A swap is silent by design, so without this there is no way to tell which
mic a recording is using or that a swap happened.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Documentation and manual verification

The unit tests cannot exercise a real device swap — no hardware, no permissions. This task is where the feature is actually confirmed to work, and it is the one that needs the user at the machine.

**Files:**
- Modify: `docs/smoke-test.md`
- Modify: `README.md` (only if it mentions the hot-swap gap; check first)

- [ ] **Step 1: Add the swap checks to the smoke test**

In `docs/smoke-test.md`, add a section before `## Permissions`:

```markdown
## Input device hot-swap

13. Start recording with AirPods connected and set as the default input. Speak,
    then disconnect the AirPods mid-recording so macOS falls back to the
    built-in mic:
    - The recording must NOT stop. The elapsed timer keeps running.
    - The mic name under the timer changes to "MacBook Pro Microphone".
    - Keep speaking for another 10 s, then Stop.
    - Play the file: speech before AND after the swap must be present on the
      left channel, with a short seam where the swap happened. This is the
      24 kHz to 48 kHz path, so listen for pitch or speed artifacts after the
      swap — there must be none.
14. The reverse: start on the built-in mic, connect AirPods mid-recording,
    confirm the same.
15. Unplug a USB mic mid-recording, confirm the same.
16. For each of the above, note how long the audible seam is. That number is the
    input to any later decision about padding the gap or switching to live
    sub-device mutation.
17. Start recording, then disconnect the ONLY input device so no replacement
    exists. The recording must stop and save, with the "The microphone changed,
    so the recording was stopped." notification — the phase 1 behavior.
```

- [ ] **Step 2: Remove the hot-swap entry from the known gaps**

In `docs/smoke-test.md`, delete this line from `## Known gaps (phase 1.5)`:

```
- Input device hot-swap stops the recording instead of continuing. Top
  priority for phase 1.5: the only complaint after a week of daily use.
```

and replace it with a line recording what the swap costs now:

```
- An input device swap drops a short window of audio on both channels while the
  aggregate is rebuilt, so a recording with swaps in it is slightly shorter than
  the elapsed time. Padding this was specced and deliberately dropped; see
  `docs/superpowers/specs/2026-09-14-scribe-input-hotswap-design.md`.
```

- [ ] **Step 3: Check the README**

```bash
grep -n -i "hot-swap\|hotswap\|device change" README.md
```

If nothing matches, no change is needed. If it does, update the wording to match.

- [ ] **Step 4: Run the manual smoke test**

Work through checks 13-17 above on the real machine, with real devices. **This needs the user at the keyboard**: connecting and disconnecting AirPods, and answering any TCC prompt, cannot be done by an agent.

Expected: every check passes. If speech after a swap sounds wrong in pitch or speed, the converter's input rate is not tracking the new device — check that `InputSwapController.performSwap` calls `writer.setInputSampleRate(next.sampleRate)` before `next.start()`, and print both rates to confirm.

- [ ] **Step 5: Commit**

```bash
git add docs/smoke-test.md README.md
git commit -m "Document the hot-swap smoke checks and the gap it leaves

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Notes for the executor

- **Tasks 3 and 4 are one shippable unit.** Task 3 leaves the writer constructed at a placeholder 48 kHz with nothing retuning it; Task 4's `start()` change adds the retune. Do not stop between them.
- **`MainActor.assumeIsolated` is the established pattern in this codebase**, not a workaround invented here — `RecordingSession.start()` already uses it to bridge a `@Sendable` Core Audio callback into main-actor state. If Swift 6 rejects one of the uses in this plan, follow that precedent rather than loosening isolation.
- **Never change the machine's default input or output device from code.** The smoke test changes devices by hand.
- **`scripts/make-dev-cert.sh` and TCC prompts need a human.** If the app re-prompts for permission after a rebuild, the dev cert is missing; ask the user to run that script rather than working around it.
