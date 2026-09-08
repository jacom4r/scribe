# Scribe Phase 1 Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A SwiftPM-built macOS menu bar app that records system audio plus the default microphone into one stereo WAV, started and stopped from a menu.

**Architecture:** `ScribeCore` is a UI-free library: a Core Audio process tap and the default mic are combined in a private aggregate device, one IO proc downmixes each callback to stereo (left = mic, right = system) and streams it to a WAV via `ExtAudioFile`. A `RecordingSession` state machine wraps that behind a protocol so it can be unit tested with fakes. Two thin executables link the library: `scribe-cli` for headless spikes and smoke tests, and `Scribe`, a SwiftUI `MenuBarExtra` app.

**Tech Stack:** Swift 6 (tools-version 6.0, strict concurrency), SwiftPM only (no Xcode.app), CoreAudio (`CATapDescription`, aggregate devices, `AudioDeviceCreateIOProcIDWithBlock`), AudioToolbox (`ExtAudioFile`), SwiftUI `MenuBarExtra`, UserNotifications, Swift Testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-09-07-scribe-phase1-recorder-design.md`

## Global Constraints

- Minimum macOS: `14.2` (`platforms: [.macOS("14.2")]`, `LSMinimumSystemVersion` 14.2). Dev machine is macOS 26.6 with Command Line Tools only.
- Bundle identifier: `com.jacobmarchionda.scribe`.
- Output file: stereo WAV, 48 kHz, 16-bit PCM. Left channel = mic (mono mix), right channel = system audio (mono mix).
- Output location and name: `~/Music/Scribe/yyyy-MM-dd HH-mm Recording.wav`, collisions get ` (2)`, ` (3)`, ...
- Usage strings: `NSAudioCaptureUsageDescription` = "Scribe records system audio so your meetings can be transcribed." and `NSMicrophoneUsageDescription` = "Scribe records your microphone during meetings."
- `ScribeCore` must not import AppKit or SwiftUI.
- Nothing on the real-time audio thread may allocate, lock, or hop to an actor. Only `downmix` and `ExtAudioFileWriteAsync` run there.
- The `Scribe` binary must always be launched from the `.app` bundle built by `scripts/bundle.sh`. Running it straight from `.build/` breaks permissions and notifications.
- No third-party packages. Argument parsing in the CLI is hand-rolled.
- Commit after every task. Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Deviation from spec, agreed here: no `AppIcon.icns` in phase 1. The app has no Dock icon, so the icon only appears in System Settings; it is deferred to phase 1.5.

---

## File Structure

| Path | Responsibility |
|---|---|
| `Package.swift` | Targets: `ScribeCore` (lib), `Scribe` (app), `scribe-cli` (tool), `ScribeCoreTests`. |
| `Sources/ScribeCore/ScribeError.swift` | The single error enum and its user-facing messages. |
| `Sources/ScribeCore/RecordingStore.swift` | Recordings directory and file naming. |
| `Sources/ScribeCore/ElapsedFormatter.swift` | `formatElapsed(_:)` for the menu timer. |
| `Sources/ScribeCore/Downmix.swift` | `InputLayout` and the pure `downmix` function. |
| `Sources/ScribeCore/StereoBuffer.swift` | Preallocated interleaved stereo scratch buffer with an `AudioBufferList` view. |
| `Sources/ScribeCore/WavWriter.swift` | `ExtAudioFile` wrapper writing 48 kHz 16-bit stereo WAV. |
| `Sources/ScribeCore/CoreAudioProperties.swift` | Small typed helpers over `AudioObjectGetPropertyData`. |
| `Sources/ScribeCore/ProcessTap.swift` | Creates and destroys the system audio tap. |
| `Sources/ScribeCore/AggregateDevice.swift` | Builds the private aggregate of mic + tap; derives `InputLayout`. |
| `Sources/ScribeCore/CaptureEngine.swift` | IO proc, per-callback downmix + write, `InterruptionRelay`. |
| `Sources/ScribeCore/DefaultInputWatcher.swift` | Fires when the default input device changes. |
| `Sources/ScribeCore/LiveCapture.swift` | `AudioCapturing` / `CaptureFactory` protocols and the real implementation owning tap, aggregate, writer, engine, watcher. |
| `Sources/ScribeCore/RecordingSession.swift` | `@MainActor @Observable` state machine: idle / recording / finalizing. |
| `Sources/scribe-cli/main.swift` | `tap`, `devices`, `record` subcommands. |
| `Sources/Scribe/ScribeApp.swift` | `@main`, `MenuBarExtra`. |
| `Sources/Scribe/MenuBarIcon.swift` | Idle / recording `NSImage` for the status item. |
| `Sources/Scribe/AppState.swift` | Owns the session, timer, last error, notifier; menu actions. |
| `Sources/Scribe/MenuView.swift` | The dropdown menu. |
| `Sources/Scribe/Notifier.swift` | UserNotifications wrapper. |
| `Resources/Info.plist` | Bundle metadata, usage strings, `LSUIElement`. |
| `scripts/bundle.sh` | Build, assemble `build/Scribe.app`, sign, launch. |
| `scripts/make-dev-cert.sh` | One-time self-signed "Scribe Dev" code signing identity. |
| `docs/smoke-test.md` | Manual checklist for the capture path and app. |
| `Tests/ScribeCoreTests/*.swift` | One test file per core unit. |

---

### Task 1: Package scaffold and toolchain check

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/ScribeCore/ScribeError.swift`, `Sources/Scribe/ScribeApp.swift` (placeholder), `Sources/scribe-cli/main.swift` (placeholder), `Tests/ScribeCoreTests/ScribeErrorTests.swift`

**Interfaces:**
- Produces: `public enum ScribeError: Error, Equatable, Sendable` with cases `permissionDenied`, `tapCreationFailed(OSStatus)`, `aggregateCreationFailed(OSStatus)`, `captureStartFailed(OSStatus)`, `noInputDevice`, `writeFailed(OSStatus)`, `inputDeviceChanged`, `notRecording`, `alreadyRecording`, and `var userMessage: String`.

- [ ] **Step 1: Configure git identity for this repo (skip if already set)**

Run:
```bash
cd /Users/jacob.marchionda/Documents/scribe
git config user.name >/dev/null || git config user.name "Jacob Marchionda"
git config user.email >/dev/null || git config user.email "jacobmarchionda@gmail.com"
```

- [ ] **Step 2: Write `.gitignore`**

```gitignore
.build/
build/
.swiftpm/
*.p12
*.pem
.DS_Store
*.xcodeproj
*.xcworkspace
```

- [ ] **Step 3: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ScribeCore", targets: ["ScribeCore"]),
        .executable(name: "Scribe", targets: ["Scribe"]),
        .executable(name: "scribe-cli", targets: ["scribe-cli"]),
    ],
    targets: [
        .target(
            name: "ScribeCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(name: "Scribe", dependencies: ["ScribeCore"]),
        .executableTarget(name: "scribe-cli", dependencies: ["ScribeCore"]),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"]),
    ]
)
```

- [ ] **Step 4: Write the failing test `Tests/ScribeCoreTests/ScribeErrorTests.swift`**

```swift
import Testing
@testable import ScribeCore

@Suite struct ScribeErrorTests {
    @Test func everyCaseHasAUserMessage() {
        let cases: [ScribeError] = [
            .permissionDenied, .tapCreationFailed(-1), .aggregateCreationFailed(-2),
            .captureStartFailed(-3), .noInputDevice, .writeFailed(-4),
            .inputDeviceChanged, .notRecording, .alreadyRecording,
        ]
        for c in cases {
            #expect(!c.userMessage.isEmpty)
        }
        #expect(ScribeError.writeFailed(-4).userMessage.contains("-4"))
    }
}
```

- [ ] **Step 5: Write placeholder executables so the package resolves**

`Sources/Scribe/ScribeApp.swift`:
```swift
import Foundation

@main
struct ScribeApp {
    static func main() {
        print("Scribe placeholder; replaced in Task 9")
    }
}
```

`Sources/scribe-cli/main.swift`:
```swift
import Foundation

print("scribe-cli placeholder; replaced in Task 5")
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `swift test 2>&1 | tail -20`
Expected: build error, `cannot find 'ScribeError' in scope` (the type does not exist yet).

- [ ] **Step 7: Write `Sources/ScribeCore/ScribeError.swift`**

```swift
import Foundation

/// Every failure the recorder can report. `userMessage` is what the menu and
/// notifications show; keep it one short sentence.
public enum ScribeError: Error, Equatable, Sendable {
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case captureStartFailed(OSStatus)
    case noInputDevice
    case writeFailed(OSStatus)
    case inputDeviceChanged
    case notRecording
    case alreadyRecording

    public var userMessage: String {
        switch self {
        case .permissionDenied:
            return "Scribe needs System Audio Recording permission."
        case .tapCreationFailed(let status):
            return "Couldn't tap system audio (error \(status))."
        case .aggregateCreationFailed(let status):
            return "Couldn't combine mic and system audio (error \(status))."
        case .captureStartFailed(let status):
            return "Couldn't start audio capture (error \(status))."
        case .noInputDevice:
            return "No microphone is available."
        case .writeFailed(let status):
            return "Couldn't write the recording (error \(status))."
        case .inputDeviceChanged:
            return "The microphone changed, so the recording was stopped."
        case .notRecording:
            return "Not recording."
        case .alreadyRecording:
            return "Already recording."
        }
    }
}
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with 1 test passed`.

- [ ] **Step 9: Verify both executables build**

Run: `swift build 2>&1 | tail -3 && .build/debug/scribe-cli`
Expected: `Build complete!` then `scribe-cli placeholder; replaced in Task 5`.

- [ ] **Step 10: Commit**

```bash
git add .gitignore Package.swift Sources Tests
git commit -m "Scaffold SwiftPM package with ScribeCore, Scribe, scribe-cli

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: RecordingStore

**Files:**
- Create: `Sources/ScribeCore/RecordingStore.swift`
- Test: `Tests/ScribeCoreTests/RecordingStoreTests.swift`

**Interfaces:**
- Produces: `public struct RecordingStore: Sendable` with `public let directory: URL`, `public init(directory: URL)`, `public static func `default`() -> RecordingStore` (`~/Music/Scribe/`), `public func newRecordingURL(at date: Date = Date()) throws -> URL`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import ScribeCore

@Suite struct RecordingStoreTests {
    private func tempStore() -> RecordingStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Scribe", isDirectory: true)
        return RecordingStore(directory: dir)
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func createsDirectoryAndNamesFile() throws {
        let store = tempStore()
        let url = try store.newRecordingURL(at: date(2026, 9, 7, 14, 32))

        #expect(url.lastPathComponent == "2026-09-07 14-32 Recording.wav")
        #expect(url.deletingLastPathComponent().path == store.directory.path)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.directory.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test func suffixesOnCollision() throws {
        let store = tempStore()
        let d = date(2026, 9, 7, 14, 32)

        let first = try store.newRecordingURL(at: d)
        try Data().write(to: first)
        let second = try store.newRecordingURL(at: d)
        #expect(second.lastPathComponent == "2026-09-07 14-32 Recording (2).wav")

        try Data().write(to: second)
        let third = try store.newRecordingURL(at: d)
        #expect(third.lastPathComponent == "2026-09-07 14-32 Recording (3).wav")
    }

    @Test func defaultStoreIsMusicScribe() {
        let store = RecordingStore.default()
        #expect(store.directory.path.hasSuffix("/Music/Scribe"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RecordingStoreTests 2>&1 | tail -10`
Expected: build error `cannot find 'RecordingStore' in scope`.

- [ ] **Step 3: Write `Sources/ScribeCore/RecordingStore.swift`**

```swift
import Foundation

/// Decides where recordings go and what they are called.
public struct RecordingStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Music/Scribe/`
    public static func `default`() -> RecordingStore {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        return RecordingStore(directory: music.appendingPathComponent("Scribe", isDirectory: true))
    }

    /// Creates the directory if needed and returns a URL that does not exist yet:
    /// `yyyy-MM-dd HH-mm Recording.wav`, then ` (2)`, ` (3)`, ... on collision.
    public func newRecordingURL(at date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "\(formatter.string(from: date)) Recording"

        var candidate = directory.appendingPathComponent("\(base).wav")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(n)).wav")
            n += 1
        }
        return candidate
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RecordingStoreTests 2>&1 | tail -5`
Expected: `3 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScribeCore/RecordingStore.swift Tests/ScribeCoreTests/RecordingStoreTests.swift
git commit -m "Add RecordingStore for output directory and file naming

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: InputLayout and downmix

**Files:**
- Create: `Sources/ScribeCore/Downmix.swift`
- Test: `Tests/ScribeCoreTests/DownmixTests.swift`

**Interfaces:**
- Produces: `public struct InputLayout: Equatable, Sendable { public var micBuffers: [Int]; public var systemBuffers: [Int]; public init(micBuffers:systemBuffers:) }` and `@discardableResult func downmix(_ input: UnsafeMutableAudioBufferListPointer, frames: Int, layout: InputLayout, into output: UnsafeMutableBufferPointer<Float>) -> Int` (internal). Output is interleaved stereo, returns frames written.

Background for the implementer: a Core Audio input callback delivers an `AudioBufferList`, one `AudioBuffer` per input stream. Within one buffer, channels are interleaved (`mNumberChannels` per frame). For our aggregate device, the mic's streams come first and the tap's stream last; `InputLayout` records which buffer indices belong to which source.

- [ ] **Step 1: Write the failing tests**

```swift
import CoreAudio
import Testing
@testable import ScribeCore

/// Owns a heap AudioBufferList built from interleaved sample arrays.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer

    init(_ buffers: [(channels: Int, interleaved: [Float])]) {
        list = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
        for (i, b) in buffers.enumerated() {
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: b.interleaved.count)
            ptr.initialize(from: b.interleaved, count: b.interleaved.count)
            list[i] = AudioBuffer(
                mNumberChannels: UInt32(b.channels),
                mDataByteSize: UInt32(b.interleaved.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(ptr))
        }
        list.count = buffers.count
    }

    deinit {
        for b in list { b.mData?.assumingMemoryBound(to: Float.self).deallocate() }
        free(list.unsafeMutablePointer)
    }
}

@Suite struct DownmixTests {
    private func run(_ input: TestBufferList, frames: Int, layout: InputLayout, capacity: Int? = nil) -> (written: Int, out: [Float]) {
        let cap = capacity ?? frames
        let out = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap * 2)
        defer { out.deallocate() }
        out.initialize(repeating: 99)
        let written = downmix(input.list, frames: frames, layout: layout, into: out)
        return (written, Array(out))
    }

    @Test func stereoMicAndMonoTap() {
        // 2 frames. Mic L/R: (0.2, 0.4), (1.0, 0.0). Tap: 0.8, -0.5
        let input = TestBufferList([
            (channels: 2, interleaved: [0.2, 0.4, 1.0, 0.0]),
            (channels: 1, interleaved: [0.8, -0.5]),
        ])
        let layout = InputLayout(micBuffers: [0], systemBuffers: [1])
        let r = run(input, frames: 2, layout: layout)

        #expect(r.written == 2)
        #expect(abs(r.out[0] - 0.3) < 1e-6)   // frame 0 left  = mean(0.2, 0.4)
        #expect(abs(r.out[1] - 0.8) < 1e-6)   // frame 0 right = tap
        #expect(abs(r.out[2] - 0.5) < 1e-6)   // frame 1 left  = mean(1.0, 0.0)
        #expect(abs(r.out[3] - -0.5) < 1e-6)  // frame 1 right
    }

    @Test func micSplitAcrossTwoMonoStreams() {
        let input = TestBufferList([
            (channels: 1, interleaved: [0.2, 0.6]),
            (channels: 1, interleaved: [0.4, 0.2]),
            (channels: 1, interleaved: [1.0, 1.0]),
        ])
        let layout = InputLayout(micBuffers: [0, 1], systemBuffers: [2])
        let r = run(input, frames: 2, layout: layout)

        #expect(abs(r.out[0] - 0.3) < 1e-6)
        #expect(abs(r.out[2] - 0.4) < 1e-6)
        #expect(abs(r.out[1] - 1.0) < 1e-6)
    }

    @Test func missingSystemBuffersGiveSilentRight() {
        let input = TestBufferList([(channels: 1, interleaved: [0.5, 0.5])])
        let layout = InputLayout(micBuffers: [0], systemBuffers: [])
        let r = run(input, frames: 2, layout: layout)

        #expect(r.out[0] == 0.5)
        #expect(r.out[1] == 0)
        #expect(r.out[3] == 0)
    }

    @Test func clampsToOutputCapacity() {
        let input = TestBufferList([
            (channels: 1, interleaved: [0.1, 0.2, 0.3, 0.4]),
            (channels: 1, interleaved: [0.1, 0.2, 0.3, 0.4]),
        ])
        let layout = InputLayout(micBuffers: [0], systemBuffers: [1])
        let r = run(input, frames: 4, layout: layout, capacity: 2)

        #expect(r.written == 2)
        #expect(abs(r.out[2] - 0.2) < 1e-6)
    }

    @Test func ignoresBufferIndicesOutOfRange() {
        let input = TestBufferList([(channels: 1, interleaved: [0.5])])
        let layout = InputLayout(micBuffers: [0], systemBuffers: [7])
        let r = run(input, frames: 1, layout: layout)

        #expect(r.out[0] == 0.5)
        #expect(r.out[1] == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DownmixTests 2>&1 | tail -10`
Expected: build error `cannot find 'InputLayout' in scope`.

- [ ] **Step 3: Write `Sources/ScribeCore/Downmix.swift`**

```swift
import CoreAudio

/// Which buffers in the aggregate device's input `AudioBufferList` carry which
/// source. Buffer `i` corresponds to input stream `i` of the device.
public struct InputLayout: Equatable, Sendable {
    public var micBuffers: [Int]
    public var systemBuffers: [Int]

    public init(micBuffers: [Int], systemBuffers: [Int]) {
        self.micBuffers = micBuffers
        self.systemBuffers = systemBuffers
    }
}

/// Mixes an input buffer list down to interleaved stereo Float32:
/// left = mean of all mic channels, right = mean of all system channels.
///
/// Real-time safe: no allocation, no locks. Writes at most `output.count / 2`
/// frames and returns how many were written. Output frames are fully
/// overwritten, so callers need not zero the buffer.
@discardableResult
func downmix(_ input: UnsafeMutableAudioBufferListPointer,
             frames: Int,
             layout: InputLayout,
             into output: UnsafeMutableBufferPointer<Float>) -> Int {
    let frames = min(frames, output.count / 2)
    guard frames > 0 else { return 0 }

    for f in 0..<frames {
        output[2 * f] = 0
        output[2 * f + 1] = 0
    }
    accumulate(input, buffers: layout.micBuffers, frames: frames, channelOffset: 0, into: output)
    accumulate(input, buffers: layout.systemBuffers, frames: frames, channelOffset: 1, into: output)
    return frames
}

private func accumulate(_ input: UnsafeMutableAudioBufferListPointer,
                        buffers: [Int],
                        frames: Int,
                        channelOffset: Int,
                        into output: UnsafeMutableBufferPointer<Float>) {
    var totalChannels = 0
    for i in buffers where i >= 0 && i < input.count {
        totalChannels += Int(input[i].mNumberChannels)
    }
    guard totalChannels > 0 else { return }
    let scale = 1 / Float(totalChannels)

    for i in buffers where i >= 0 && i < input.count {
        let buffer = input[i]
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0, let data = buffer.mData else { continue }
        let available = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
        let samples = data.assumingMemoryBound(to: Float.self)
        let n = min(frames, available)
        for f in 0..<n {
            var sum: Float = 0
            for c in 0..<channels {
                sum += samples[f * channels + c]
            }
            output[2 * f + channelOffset] += sum * scale
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DownmixTests 2>&1 | tail -5`
Expected: `5 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScribeCore/Downmix.swift Tests/ScribeCoreTests/DownmixTests.swift
git commit -m "Add InputLayout and real-time-safe stereo downmix

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: StereoBuffer and WavWriter

**Files:**
- Create: `Sources/ScribeCore/StereoBuffer.swift`, `Sources/ScribeCore/WavWriter.swift`
- Test: `Tests/ScribeCoreTests/WavWriterTests.swift`

**Interfaces:**
- Produces: `public final class StereoBuffer { init(capacityFrames: Int); let capacityFrames: Int; let samples: UnsafeMutableBufferPointer<Float>; func bufferList(frames: Int) -> UnsafePointer<AudioBufferList> }`.
- Produces: `public final class WavWriter: @unchecked Sendable { static let fileSampleRate: Double = 48_000; let url: URL; init(url: URL, inputSampleRate: Double) throws; func prime() throws; func writeAsync(frames: UInt32, _ list: UnsafePointer<AudioBufferList>) -> OSStatus; func write(frames: UInt32, _ list: UnsafePointer<AudioBufferList>) throws; func close() throws }`.

Background: `ExtAudioFile` converts from a "client format" (what we hand it: Float32 interleaved stereo at the device rate) to the file format (16-bit PCM stereo at 48 kHz). `ExtAudioFileWriteAsync` is the only write call safe on the audio thread; Apple requires one zero-frame priming call from a normal thread first so it can allocate its internal ring buffer. `ExtAudioFileDispose` flushes pending async writes and finalizes the WAV header.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WavWriterTests 2>&1 | tail -10`
Expected: build error `cannot find 'WavWriter' in scope`.

- [ ] **Step 3: Write `Sources/ScribeCore/StereoBuffer.swift`**

```swift
import CoreAudio

/// A preallocated interleaved stereo Float32 buffer plus a one-buffer
/// `AudioBufferList` pointing at it. Allocated once, reused on the audio thread.
public final class StereoBuffer {
    public let capacityFrames: Int
    public let samples: UnsafeMutableBufferPointer<Float>
    private let list: UnsafeMutablePointer<AudioBufferList>

    public init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
        samples = .allocate(capacity: capacityFrames * 2)
        samples.initialize(repeating: 0)
        list = .allocate(capacity: 1)
        list.initialize(to: AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: 0,
                mData: UnsafeMutableRawPointer(samples.baseAddress))))
    }

    /// The list, sized to `frames` frames. Real-time safe.
    public func bufferList(frames: Int) -> UnsafePointer<AudioBufferList> {
        let frames = min(max(frames, 0), capacityFrames)
        list.pointee.mBuffers.mDataByteSize = UInt32(frames * 2 * MemoryLayout<Float>.size)
        return UnsafePointer(list)
    }

    deinit {
        samples.deallocate()
        list.deallocate()
    }
}
```

- [ ] **Step 4: Write `Sources/ScribeCore/WavWriter.swift`**

```swift
import AudioToolbox
import CoreAudio
import Foundation

/// Writes interleaved Float32 stereo audio to a 16-bit PCM stereo WAV at 48 kHz.
/// `writeAsync` is safe on the real-time audio thread once `prime()` has run.
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter WavWriterTests 2>&1 | tail -5`
Expected: `5 tests passed`. If `resamplesFrom44100` is off by more than 64 frames, print `file.length` and widen the tolerance to what the converter actually produces; the point of the test is that the rate is 48 kHz and the length is roughly scaled.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScribeCore/StereoBuffer.swift Sources/ScribeCore/WavWriter.swift Tests/ScribeCoreTests/WavWriterTests.swift
git commit -m "Add WavWriter (ExtAudioFile, 48k 16-bit stereo) and StereoBuffer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Core Audio helpers, ProcessTap, and `scribe-cli tap`

**Files:**
- Create: `Sources/ScribeCore/CoreAudioProperties.swift`, `Sources/ScribeCore/ProcessTap.swift`
- Modify: `Sources/scribe-cli/main.swift` (replace placeholder)

**Interfaces:**
- Produces: `enum CoreAudio` (internal) with `static func defaultInputDevice() throws -> AudioDeviceID`, `static func uid(of: AudioObjectID) throws -> String`, `static func name(of: AudioObjectID) -> String`, `static func nominalSampleRate(of: AudioDeviceID) throws -> Double`, `static func inputStreamChannelCounts(of: AudioDeviceID) throws -> [Int]`.
- Produces: `public final class ProcessTap { public init() throws; public let objectID: AudioObjectID; public let uid: String; public let format: AudioStreamBasicDescription }`. Destroys the tap in `deinit`.

Background: `CATapDescription(monoGlobalTapButExcludeProcesses: [])` describes a tap of every process's output, mixed to mono. `AudioHardwareCreateProcessTap` turns it into an `AudioObjectID`. The tap's UUID string is what an aggregate device uses to reference it. The first call from an app triggers the "System Audio Recording" permission prompt; for `scribe-cli` that prompt is attributed to whatever terminal app runs it.

This task has no unit test: it needs hardware and a permission grant. It is verified by the CLI.

- [ ] **Step 1: Write `Sources/ScribeCore/CoreAudioProperties.swift`**

```swift
import CoreAudio
import Foundation

/// Typed wrappers around the handful of Core Audio properties Scribe reads.
enum CoreAudio {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInputDevice() throws -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { throw ScribeError.noInputDevice }
        return id
    }

    static func uid(of object: AudioObjectID) throws -> String {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr else { throw ScribeError.noInputDevice }
        return value as String
    }

    static func name(of object: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? (value as String) : "Unknown"
    }

    static func nominalSampleRate(of device: AudioDeviceID) throws -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { throw ScribeError.aggregateCreationFailed(status) }
        return rate
    }

    /// Channel count of each input stream of `device`, in stream order.
    static func inputStreamChannelCounts(of device: AudioDeviceID) throws -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { throw ScribeError.aggregateCreationFailed(status) }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw)
        guard status == noErr else { throw ScribeError.aggregateCreationFailed(status) }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
```

- [ ] **Step 2: Write `Sources/ScribeCore/ProcessTap.swift`**

```swift
import CoreAudio
import Foundation

/// A Core Audio process tap on the mixed output of every process.
/// Mono, private (not visible to other apps), unmuted (the user still hears audio).
public final class ProcessTap {
    public let objectID: AudioObjectID
    public let uid: String
    public let format: AudioStreamBasicDescription

    public init() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Scribe System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw ScribeError.tapCreationFailed(status)
        }
        objectID = id
        uid = description.uuid.uuidString

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &asbd)
        guard formatStatus == noErr else {
            AudioHardwareDestroyProcessTap(id)
            throw ScribeError.tapCreationFailed(formatStatus)
        }
        format = asbd
    }

    deinit {
        AudioHardwareDestroyProcessTap(objectID)
    }
}
```

- [ ] **Step 3: Replace `Sources/scribe-cli/main.swift`**

```swift
import Foundation
import ScribeCore

let usage = "usage: scribe-cli tap | devices | record <seconds> [directory]"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "tap":
    do {
        let tap = try ProcessTap()
        print("Tap created: id=\(tap.objectID) uid=\(tap.uid)")
        print("Tap format: \(tap.format.mSampleRate) Hz, \(tap.format.mChannelsPerFrame) ch, bits=\(tap.format.mBitsPerChannel)")
    } catch {
        fail("tap failed: \(error)")
    }

default:
    fail(usage)
}
```

- [ ] **Step 4: Build and run the tap check**

Run: `swift build 2>&1 | tail -3 && .build/debug/scribe-cli tap`
Expected: a macOS prompt asking to allow your terminal app (Terminal, VS Code, etc.) to record system audio. Allow it. Then output like:
```
Tap created: id=123 uid=XXXXXXXX-XXXX-...
Tap format: 48000.0 Hz, 1 ch, bits=32
```
If the format shows 2 channels, the mono flag did not take effect; that is fine, `downmix` averages whatever channels arrive.

- [ ] **Step 5: Observe what a permission denial looks like and record it**

Open System Settings → Privacy & Security → Screen & System Audio Recording, and turn OFF the entry for your terminal app. Run `.build/debug/scribe-cli tap` again.

Two possible outcomes. Note which one you saw in the commit message of this task:
- (a) `tap failed: tapCreationFailed(<status>)`. Then edit `ProcessTap.init` so that this exact status maps to `ScribeError.permissionDenied` instead of `tapCreationFailed`.
- (b) The tap is created normally. Then permission denial is not detectable at creation time and the tap will simply deliver silence. Leave `ProcessTap` as is. Task 10 handles this case by always showing a "Recording Permissions…" menu item, and Task 13 documents it.

Turn the permission back ON afterwards.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScribeCore/CoreAudioProperties.swift Sources/ScribeCore/ProcessTap.swift Sources/scribe-cli/main.swift
git commit -m "Add ProcessTap and Core Audio property helpers; scribe-cli tap

Permission denial observed as: <a or b, one line>

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: AggregateDevice and `scribe-cli devices`

**Files:**
- Create: `Sources/ScribeCore/AggregateDevice.swift`
- Modify: `Sources/scribe-cli/main.swift`
- Test: `Tests/ScribeCoreTests/AggregateDeviceTests.swift`

**Interfaces:**
- Consumes: `ProcessTap` (`.uid`), `CoreAudio.*`, `InputLayout`.
- Produces: `public final class AggregateDevice { public init(tap: ProcessTap) throws; public let deviceID: AudioDeviceID; public let layout: InputLayout; public let sampleRate: Double; public let micName: String; static func makeLayout(aggregateStreams: [Int], micStreams: [Int]) -> InputLayout }`. Destroys the device in `deinit`.

Background: an aggregate device is a virtual device Core Audio builds from sub-devices (here: the mic) and taps. The "main" sub-device provides the clock; everything else gets drift compensation, meaning Core Audio resamples it to stay aligned with the main clock. In the aggregate's input stream list, sub-device streams come first, then tap streams. `makeLayout` encodes that assumption and Task 7's spike verifies it.

- [ ] **Step 1: Write the failing test for the pure layout function**

```swift
import Testing
@testable import ScribeCore

@Suite struct AggregateDeviceTests {
    @Test func stereoMicThenMonoTap() {
        let layout = AggregateDevice.makeLayout(aggregateStreams: [2, 1], micStreams: [2])
        #expect(layout == InputLayout(micBuffers: [0], systemBuffers: [1]))
    }

    @Test func multiStreamMic() {
        let layout = AggregateDevice.makeLayout(aggregateStreams: [1, 1, 1], micStreams: [1, 1])
        #expect(layout == InputLayout(micBuffers: [0, 1], systemBuffers: [2]))
    }

    @Test func tapMissingGivesNoSystemBuffers() {
        let layout = AggregateDevice.makeLayout(aggregateStreams: [1], micStreams: [1])
        #expect(layout == InputLayout(micBuffers: [0], systemBuffers: []))
    }

    @Test func fewerAggregateStreamsThanMicStreamsDoesNotCrash() {
        let layout = AggregateDevice.makeLayout(aggregateStreams: [1], micStreams: [1, 1])
        #expect(layout == InputLayout(micBuffers: [0], systemBuffers: []))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AggregateDeviceTests 2>&1 | tail -10`
Expected: build error `cannot find 'AggregateDevice' in scope`.

- [ ] **Step 3: Write `Sources/ScribeCore/AggregateDevice.swift`**

```swift
import CoreAudio
import Foundation

/// A private aggregate device made of the current default input device (clock
/// master) and a system audio tap (drift compensated). Its input streams are
/// the mic's streams followed by the tap's stream.
public final class AggregateDevice {
    public let deviceID: AudioDeviceID
    public let layout: InputLayout
    public let sampleRate: Double
    public let micName: String

    public init(tap: ProcessTap) throws {
        let mic = try CoreAudio.defaultInputDevice()
        let micUID = try CoreAudio.uid(of: mic)
        let micStreams = try CoreAudio.inputStreamChannelCounts(of: mic)
        micName = CoreAudio.name(of: mic)

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Scribe Recorder",
            kAudioAggregateDeviceUIDKey as String: "com.jacobmarchionda.scribe.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: micUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: micUID,
                    kAudioSubDeviceDriftCompensationKey as String: 0,
                ],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tap.uid,
                    kAudioSubTapDriftCompensationKey as String: 1,
                ],
            ],
        ]

        var id = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw ScribeError.aggregateCreationFailed(status)
        }
        deviceID = id

        do {
            sampleRate = try CoreAudio.nominalSampleRate(of: id)
            let streams = try CoreAudio.inputStreamChannelCounts(of: id)
            layout = Self.makeLayout(aggregateStreams: streams, micStreams: micStreams)
        } catch {
            AudioHardwareDestroyAggregateDevice(id)
            throw error
        }
    }

    /// Sub-device streams come first in an aggregate's stream list, taps last.
    static func makeLayout(aggregateStreams: [Int], micStreams: [Int]) -> InputLayout {
        let micCount = min(micStreams.count, aggregateStreams.count)
        return InputLayout(
            micBuffers: Array(0..<micCount),
            systemBuffers: Array(micCount..<aggregateStreams.count))
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AggregateDeviceTests 2>&1 | tail -5`
Expected: `4 tests passed`.

- [ ] **Step 5: Add the `devices` subcommand to `Sources/scribe-cli/main.swift`**

Insert this case before `default:`:

```swift
case "devices":
    do {
        let tap = try ProcessTap()
        let aggregate = try AggregateDevice(tap: tap)
        print("Mic: \(aggregate.micName)")
        print("Aggregate device id=\(aggregate.deviceID) rate=\(aggregate.sampleRate) Hz")
        print("Layout: mic buffers=\(aggregate.layout.micBuffers) system buffers=\(aggregate.layout.systemBuffers)")
    } catch {
        fail("devices failed: \(error)")
    }
```

- [ ] **Step 6: Build and run**

Run: `swift build 2>&1 | tail -1 && .build/debug/scribe-cli devices`
Expected: a microphone permission prompt for your terminal app on first run (allow it), then something like:
```
Mic: MacBook Pro Microphone
Aggregate device id=98 rate=48000.0 Hz
Layout: mic buffers=[0] system buffers=[1]
```
`system buffers` must be non-empty. If it is empty, the tap was not added to the aggregate: check that `tap.uid` is the description's UUID string and that `kAudioAggregateDeviceTapListKey` is spelled via the constant, not a literal.

- [ ] **Step 7: Commit**

```bash
git add Sources/ScribeCore/AggregateDevice.swift Sources/scribe-cli/main.swift Tests/ScribeCoreTests/AggregateDeviceTests.swift
git commit -m "Add AggregateDevice combining default mic and system tap

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: CaptureEngine, InterruptionRelay, and the phase 0 spike (`scribe-cli record`)

**Files:**
- Create: `Sources/ScribeCore/CaptureEngine.swift`
- Modify: `Sources/scribe-cli/main.swift`

**Interfaces:**
- Consumes: `InputLayout`, `downmix`, `StereoBuffer`, `WavWriter`, `ScribeError`.
- Produces: `public final class InterruptionRelay: @unchecked Sendable { public init(); public var handler: (@Sendable (ScribeError) -> Void)?; public func fire(_ error: ScribeError) }` which delivers at most one error to `handler` on the main queue.
- Produces: `public final class CaptureEngine { public init(deviceID: AudioDeviceID, layout: InputLayout, writer: WavWriter, relay: InterruptionRelay, capacityFrames: Int = 8192); public func start() throws; public func stop() }`.

This task ends with the **phase 0 gate**: a 10-second recording on the dev machine with voice on the left channel and system audio on the right. Nothing in Tasks 8 to 13 starts until that passes.

- [ ] **Step 1: Write `Sources/ScribeCore/CaptureEngine.swift`**

```swift
import AudioToolbox
import CoreAudio
import Foundation

/// Delivers at most one interruption to `handler`, always on the main queue.
/// Safe to call from any thread, including the audio thread on its failure path.
public final class InterruptionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var storedHandler: (@Sendable (ScribeError) -> Void)?

    public init() {}

    public var handler: (@Sendable (ScribeError) -> Void)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    public func fire(_ error: ScribeError) {
        let first: Bool = lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
        guard first else { return }
        let handler = self.handler
        DispatchQueue.main.async { handler?(error) }
    }
}

/// State touched on the real-time audio thread. Everything here is allocated
/// before `start()` and never resized.
private final class IOState: @unchecked Sendable {
    let layout: InputLayout
    let writer: WavWriter
    let scratch: StereoBuffer
    let relay: InterruptionRelay
    var failed = false

    init(layout: InputLayout, writer: WavWriter, relay: InterruptionRelay, capacityFrames: Int) {
        self.layout = layout
        self.writer = writer
        self.relay = relay
        self.scratch = StereoBuffer(capacityFrames: capacityFrames)
    }

    func process(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0 else { return }
        let first = list[0]
        let channels = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (channels * MemoryLayout<Float>.size)

        let written = downmix(list, frames: frames, layout: layout, into: scratch.samples)
        guard written > 0 else { return }

        let status = writer.writeAsync(frames: UInt32(written), scratch.bufferList(frames: written))
        if status != noErr && !failed {
            failed = true
            relay.fire(.writeFailed(status))
        }
    }
}

/// Runs an IO proc on a device, downmixes every input callback to stereo, and
/// streams it to a `WavWriter`. Write failures are reported through the relay.
public final class CaptureEngine {
    private let deviceID: AudioDeviceID
    private let state: IOState
    private var procID: AudioDeviceIOProcID?

    public init(deviceID: AudioDeviceID, layout: InputLayout, writer: WavWriter,
                relay: InterruptionRelay, capacityFrames: Int = 8192) {
        self.deviceID = deviceID
        self.state = IOState(layout: layout, writer: writer, relay: relay, capacityFrames: capacityFrames)
    }

    public func start() throws {
        guard procID == nil else { return }
        try state.writer.prime()

        let state = self.state
        var created: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&created, deviceID, nil) { _, inputData, _, _, _ in
            state.process(inputData)
        }
        guard status == noErr, let proc = created else {
            throw ScribeError.captureStartFailed(status)
        }

        status = AudioDeviceStart(deviceID, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, proc)
            throw ScribeError.captureStartFailed(status)
        }
        procID = proc
    }

    public func stop() {
        guard let proc = procID else { return }
        AudioDeviceStop(deviceID, proc)
        AudioDeviceDestroyIOProcID(deviceID, proc)
        procID = nil
    }

    deinit {
        stop()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | grep -E "error|warning|Compiling|Build" | tail -10`
Expected: `Build complete!`. If Swift 6 complains that the IO block captures non-Sendable state, `IOState` is already `@unchecked Sendable`; check the capture is the local `let state` and not `self`.

- [ ] **Step 3: Add the `record` subcommand to `Sources/scribe-cli/main.swift`**

Insert before `default:`:

```swift
case "record":
    guard args.count >= 2, let seconds = Double(args[1]), seconds > 0 else { fail(usage) }
    let directory = URL(fileURLWithPath: args.count >= 3 ? args[2] : FileManager.default.currentDirectoryPath, isDirectory: true)
    let url = directory.appendingPathComponent("scribe-\(Int(Date().timeIntervalSince1970)).wav")
    do {
        let tap = try ProcessTap()
        let aggregate = try AggregateDevice(tap: tap)
        print("Mic: \(aggregate.micName) @ \(aggregate.sampleRate) Hz; layout mic=\(aggregate.layout.micBuffers) system=\(aggregate.layout.systemBuffers)")

        let writer = try WavWriter(url: url, inputSampleRate: aggregate.sampleRate)
        let relay = InterruptionRelay()
        relay.handler = { error in fail("interrupted: \(error.userMessage)") }
        let engine = CaptureEngine(deviceID: aggregate.deviceID, layout: aggregate.layout, writer: writer, relay: relay)

        try engine.start()
        print("Recording \(Int(seconds))s to \(url.path) ... speak into the mic and play some audio.")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        engine.stop()
        try writer.close()
        print("Saved \(url.path)")
    } catch {
        fail("record failed: \(error)")
    }
```

- [ ] **Step 4: Phase 0 gate: record and verify both channels**

Start music or a video playing at a normal volume. Run:
```bash
swift build 2>&1 | tail -1 && .build/debug/scribe-cli record 10 /tmp
```
Speak continuously into the mic for the 10 seconds. Then inspect the file. Two checks, both must pass:

1. Format:
```bash
afinfo /tmp/scribe-*.wav | grep -E "Data format|estimated duration"
```
Expected: `2 ch, 48000 Hz, Int16` and a duration near 10 s.

2. Channel content. Open the file in QuickTime Player or Audacity. Left should contain your voice only, right should contain the music only. If you have no editor handy, this one-off check prints per-channel RMS:
```bash
cat > /tmp/rms.swift <<'EOF'
import AVFoundation
let file = try! AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try! file.read(into: buf)
for ch in 0..<Int(buf.format.channelCount) {
    let p = buf.floatChannelData![ch]; var s: Float = 0
    for i in 0..<Int(buf.frameLength) { s += p[i] * p[i] }
    print("channel \(ch) rms=\((s / Float(buf.frameLength)).squareRoot())")
}
EOF
swift /tmp/rms.swift /tmp/scribe-*.wav
```
Both channels must have RMS clearly above 0.001. To confirm the assignment, record once more with the music paused while speaking: channel 0 RMS should stay high and channel 1 should drop to near zero.

- [ ] **Step 5: If the channels are swapped**

If voice landed on channel 1 and music on channel 0, the aggregate lists tap streams before sub-device streams. Change `AggregateDevice.makeLayout` to put the last `micStreams.count` indices in `micBuffers` and the rest in `systemBuffers`, update the four tests in `AggregateDeviceTests` to match, rerun `swift test --filter AggregateDeviceTests`, and repeat Step 4.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScribeCore/CaptureEngine.swift Sources/scribe-cli/main.swift
git commit -m "Add CaptureEngine and scribe-cli record; phase 0 spike passes

Verified on <mic name>: left=mic, right=system, 48k stereo.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Capture protocols, LiveCapture, RecordingSession, formatElapsed

**Files:**
- Create: `Sources/ScribeCore/LiveCapture.swift`, `Sources/ScribeCore/RecordingSession.swift`, `Sources/ScribeCore/ElapsedFormatter.swift`
- Modify: `Sources/scribe-cli/main.swift` (`record` uses the session)
- Test: `Tests/ScribeCoreTests/RecordingSessionTests.swift`, `Tests/ScribeCoreTests/ElapsedFormatterTests.swift`

**Interfaces:**
- Consumes: `ProcessTap`, `AggregateDevice`, `WavWriter`, `CaptureEngine`, `InterruptionRelay`, `RecordingStore`, `ScribeError`.
- Produces:
  - `public protocol AudioCapturing: AnyObject { var onInterrupted: (@Sendable (ScribeError) -> Void)? { get set }; func start() throws; func stop() throws }`. `onInterrupted` is always invoked on the main thread.
  - `public protocol CaptureFactory { func makeCapture(url: URL) throws -> any AudioCapturing }`
  - `public struct LiveCaptureFactory: CaptureFactory { public init() }`
  - `@MainActor @Observable public final class RecordingSession` with `enum State: Equatable, Sendable { idle, recording(since: Date, url: URL), finalizing }`, `public private(set) var state`, `public let store: RecordingStore`, `public var onInterrupted: ((ScribeError, URL) -> Void)?`, `public init(store: RecordingStore, factory: any CaptureFactory)`, `public convenience init(store: RecordingStore = .default())`, `public var isRecording: Bool`, `public func elapsed(at now: Date = Date()) -> TimeInterval`, `@discardableResult public func start(now: Date = Date()) throws -> URL`, `@discardableResult public func stop() throws -> URL`.
  - `public func formatElapsed(_ seconds: TimeInterval) -> String` → `"0:00"`, `"12:34"`, `"1:02:03"`.

- [ ] **Step 1: Write the failing elapsed formatter test**

`Tests/ScribeCoreTests/ElapsedFormatterTests.swift`:
```swift
import Testing
@testable import ScribeCore

@Suite struct ElapsedFormatterTests {
    @Test func formatsMinutesAndSeconds() {
        #expect(formatElapsed(0) == "0:00")
        #expect(formatElapsed(5.9) == "0:05")
        #expect(formatElapsed(65) == "1:05")
        #expect(formatElapsed(754) == "12:34")
    }

    @Test func formatsHours() {
        #expect(formatElapsed(3600) == "1:00:00")
        #expect(formatElapsed(3725) == "1:02:05")
    }

    @Test func clampsNegative() {
        #expect(formatElapsed(-3) == "0:00")
    }
}
```

- [ ] **Step 2: Write the failing session tests**

`Tests/ScribeCoreTests/RecordingSessionTests.swift`:
```swift
import Foundation
import Testing
@testable import ScribeCore

final class FakeCapture: AudioCapturing {
    var onInterrupted: (@Sendable (ScribeError) -> Void)?
    var started = false
    var stopped = false
    var startError: ScribeError?

    func start() throws {
        if let startError { throw startError }
        started = true
    }

    func stop() throws {
        stopped = true
    }
}

final class FakeFactory: CaptureFactory {
    var capture = FakeCapture()
    var makeError: ScribeError?
    var lastURL: URL?

    func makeCapture(url: URL) throws -> any AudioCapturing {
        lastURL = url
        if let makeError { throw makeError }
        return capture
    }
}

@MainActor
@Suite struct RecordingSessionTests {
    private func makeSession() -> (RecordingSession, FakeFactory, RecordingStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-session-\(UUID().uuidString)", isDirectory: true)
        let store = RecordingStore(directory: dir)
        let factory = FakeFactory()
        return (RecordingSession(store: store, factory: factory), factory, store)
    }

    @Test func startsRecordingAtStoreURL() throws {
        let (session, factory, store) = makeSession()
        let now = Date()

        let url = try session.start(now: now)

        #expect(url.deletingLastPathComponent().path == store.directory.path)
        #expect(factory.lastURL == url)
        #expect(factory.capture.started)
        #expect(session.isRecording)
        #expect(session.state == .recording(since: now, url: url))
        #expect(session.elapsed(at: now.addingTimeInterval(5)) == 5)
    }

    @Test func stopReturnsURLAndIdles() throws {
        let (session, factory, _) = makeSession()
        let url = try session.start()

        let stopped = try session.stop()

        #expect(stopped == url)
        #expect(factory.capture.stopped)
        #expect(session.state == .idle)
        #expect(session.elapsed() == 0)
    }

    @Test func startTwiceThrows() throws {
        let (session, _, _) = makeSession()
        try session.start()
        #expect(throws: ScribeError.alreadyRecording) { try session.start() }
    }

    @Test func stopWhenIdleThrows() {
        let (session, _, _) = makeSession()
        #expect(throws: ScribeError.notRecording) { try session.stop() }
    }

    @Test func factoryFailureLeavesIdle() {
        let (session, factory, _) = makeSession()
        factory.makeError = .permissionDenied

        #expect(throws: ScribeError.permissionDenied) { try session.start() }
        #expect(session.state == .idle)
    }

    @Test func startFailureUnwindsAndRemovesFile() throws {
        let (session, factory, _) = makeSession()
        factory.capture.startError = .captureStartFailed(-1)

        #expect(throws: ScribeError.captureStartFailed(-1)) { try session.start() }

        #expect(session.state == .idle)
        #expect(factory.capture.stopped)
        let url = try #require(factory.lastURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func interruptionStopsAndReports() throws {
        let (session, factory, _) = makeSession()
        var reported: (ScribeError, URL)?
        session.onInterrupted = { error, url in reported = (error, url) }
        let url = try session.start()

        factory.capture.onInterrupted?(.inputDeviceChanged)

        #expect(session.state == .idle)
        #expect(factory.capture.stopped)
        #expect(reported?.0 == .inputDeviceChanged)
        #expect(reported?.1 == url)
    }

    @Test func interruptionAfterStopIsIgnored() throws {
        let (session, factory, _) = makeSession()
        var calls = 0
        session.onInterrupted = { _, _ in calls += 1 }
        try session.start()
        try session.stop()

        factory.capture.onInterrupted?(.inputDeviceChanged)

        #expect(calls == 0)
        #expect(session.state == .idle)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter "RecordingSessionTests|ElapsedFormatterTests" 2>&1 | tail -10`
Expected: build errors `cannot find 'RecordingSession' in scope`, `cannot find 'formatElapsed' in scope`.

- [ ] **Step 4: Write `Sources/ScribeCore/ElapsedFormatter.swift`**

```swift
import Foundation

/// "0:00", "12:34", or "1:02:03" once it passes an hour.
public func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%d:%02d", m, s)
}
```

- [ ] **Step 5: Write `Sources/ScribeCore/LiveCapture.swift`**

```swift
import Foundation

/// One recording's worth of audio capture. `onInterrupted` is called on the
/// main thread when capture stops for a reason other than `stop()`.
public protocol AudioCapturing: AnyObject {
    var onInterrupted: (@Sendable (ScribeError) -> Void)? { get set }
    func start() throws
    func stop() throws
}

public protocol CaptureFactory {
    func makeCapture(url: URL) throws -> any AudioCapturing
}

/// The real thing: tap + aggregate + writer + engine for one file.
/// Teardown order matters: engine, writer, aggregate, then tap.
final class LiveCapture: AudioCapturing {
    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private let writer: WavWriter
    private let engine: CaptureEngine
    private let relay = InterruptionRelay()

    var onInterrupted: (@Sendable (ScribeError) -> Void)? {
        didSet { relay.handler = onInterrupted }
    }

    init(url: URL) throws {
        let tap = try ProcessTap()
        let aggregate = try AggregateDevice(tap: tap)
        let writer = try WavWriter(url: url, inputSampleRate: aggregate.sampleRate)
        self.tap = tap
        self.aggregate = aggregate
        self.writer = writer
        self.engine = CaptureEngine(
            deviceID: aggregate.deviceID, layout: aggregate.layout, writer: writer, relay: relay)
    }

    func start() throws {
        try engine.start()
    }

    func stop() throws {
        engine.stop()
        defer {
            aggregate = nil
            tap = nil
        }
        try writer.close()
    }

    deinit {
        engine.stop()
        try? writer.close()
        aggregate = nil
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

- [ ] **Step 6: Write `Sources/ScribeCore/RecordingSession.swift`**

```swift
import Foundation
import Observation

/// The recorder's state machine. Main-actor only.
@MainActor
@Observable
public final class RecordingSession {
    public enum State: Equatable, Sendable {
        case idle
        case recording(since: Date, url: URL)
        case finalizing
    }

    public private(set) var state: State = .idle
    public let store: RecordingStore

    /// Called when a recording stops on its own (device change, write failure).
    /// Not called for a user-initiated `stop()`.
    public var onInterrupted: ((ScribeError, URL) -> Void)?

    private let factory: any CaptureFactory
    private var capture: (any AudioCapturing)?

    public init(store: RecordingStore, factory: any CaptureFactory) {
        self.store = store
        self.factory = factory
    }

    public convenience init(store: RecordingStore = .default()) {
        self.init(store: store, factory: LiveCaptureFactory())
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    public func elapsed(at now: Date = Date()) -> TimeInterval {
        if case .recording(let since, _) = state { return now.timeIntervalSince(since) }
        return 0
    }

    @discardableResult
    public func start(now: Date = Date()) throws -> URL {
        guard case .idle = state else { throw ScribeError.alreadyRecording }

        let url = try store.newRecordingURL(at: now)
        let capture = try factory.makeCapture(url: url)
        capture.onInterrupted = { [weak self] error in
            MainActor.assumeIsolated {
                self?.handleInterruption(error)
            }
        }

        do {
            try capture.start()
        } catch {
            try? capture.stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        self.capture = capture
        state = .recording(since: now, url: url)
        return url
    }

    @discardableResult
    public func stop() throws -> URL {
        guard case .recording(_, let url) = state, let capture else {
            throw ScribeError.notRecording
        }
        state = .finalizing
        self.capture = nil
        defer { state = .idle }
        try capture.stop()
        return url
    }

    private func handleInterruption(_ error: ScribeError) {
        guard case .recording(_, let url) = state else { return }
        try? stop()
        onInterrupted?(error, url)
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: all suites pass (`ScribeError`, `RecordingStore`, `Downmix`, `AggregateDevice`, `WavWriter`, `ElapsedFormatter`, `RecordingSession`). If `MainActor.assumeIsolated` traps in `interruptionStopsAndReports`, the test is not on the main actor: confirm the suite is annotated `@MainActor`.

- [ ] **Step 8: Switch `scribe-cli record` to the session**

Replace the whole `case "record":` block in `Sources/scribe-cli/main.swift` with:

```swift
case "record":
    guard args.count >= 2, let seconds = Double(args[1]), seconds > 0 else { fail(usage) }
    let directory = URL(fileURLWithPath: args.count >= 3 ? args[2] : FileManager.default.currentDirectoryPath, isDirectory: true)
    let session = RecordingSession(store: RecordingStore(directory: directory))
    session.onInterrupted = { error, url in
        fail("interrupted: \(error.userMessage) (partial file at \(url.path))")
    }
    do {
        let url = try session.start()
        print("Recording \(Int(seconds))s to \(url.path) ... speak into the mic and play some audio.")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        try session.stop()
        print("Saved \(url.path)")
    } catch {
        fail("record failed: \(error)")
    }
```

Top-level code in `main.swift` is main-actor isolated under Swift 6, so calling the `@MainActor` session here compiles without extra annotation.

- [ ] **Step 9: Re-run the spike through the session**

Run: `swift build 2>&1 | tail -1 && .build/debug/scribe-cli record 5 /tmp && afinfo /tmp/*Recording*.wav | grep "Data format"`
Expected: a file named like `/tmp/2026-09-07 15-04 Recording.wav`, `2 ch, 48000 Hz, Int16`.

- [ ] **Step 10: Commit**

```bash
git add Sources/ScribeCore/LiveCapture.swift Sources/ScribeCore/RecordingSession.swift Sources/ScribeCore/ElapsedFormatter.swift Sources/scribe-cli/main.swift Tests/ScribeCoreTests/RecordingSessionTests.swift Tests/ScribeCoreTests/ElapsedFormatterTests.swift
git commit -m "Add RecordingSession state machine, LiveCapture, formatElapsed

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Info.plist, signing and bundle scripts, menu bar app shell

**Files:**
- Create: `Resources/Info.plist`, `scripts/make-dev-cert.sh`, `scripts/bundle.sh`, `Sources/Scribe/MenuBarIcon.swift`, `Sources/Scribe/AppState.swift`, `Sources/Scribe/MenuView.swift`
- Modify: `Sources/Scribe/ScribeApp.swift` (replace placeholder)

**Interfaces:**
- Consumes: `RecordingSession`, `RecordingStore`.
- Produces: `@MainActor @Observable final class AppState` with `let session: RecordingSession`, `var isRecording: Bool`, `var recordingsDirectory: URL`, `func openRecordingsFolder()`, `func quit()`. Task 10 adds `toggle()`, `elapsedText`, `lastError`, `openPrivacySettings()`.
- Produces: `enum MenuBarIcon { static func image(recording: Bool) -> NSImage }`.

The deliverable is a running menu bar app with a working "Open Recordings Folder" and "Quit Scribe", launched from a signed bundle. Recording is wired in Task 10.

- [ ] **Step 1: Write `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Scribe</string>
    <key>CFBundleIdentifier</key>
    <string>com.jacobmarchionda.scribe</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Scribe</string>
    <key>CFBundleDisplayName</key>
    <string>Scribe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Scribe records system audio so your meetings can be transcribed.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Scribe records your microphone during meetings.</string>
</dict>
</plist>
```

- [ ] **Step 2: Write `scripts/make-dev-cert.sh`**

```bash
#!/usr/bin/env bash
# Creates a self-signed code signing identity named "Scribe Dev" in the login
# keychain, once. A stable identity keeps macOS's audio permission grant valid
# across rebuilds; ad-hoc signatures change every build and re-prompt.
set -euo pipefail

NAME="Scribe Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "'$NAME' already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"

# OpenSSL 3 needs -legacy for a PKCS#12 that `security import` accepts;
# LibreSSL (macOS default) has no -legacy flag and produces a compatible file.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/scribe-dev.p12" -passout pass:scribe 2>/dev/null \
|| openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/scribe-dev.p12" -passout pass:scribe

security import "$TMP/scribe-dev.p12" -k "$KEYCHAIN" -P scribe \
  -T /usr/bin/codesign -T /usr/bin/security
# Trust it for code signing (may prompt for your login password).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Created '$NAME'. The first codesign may show a keychain prompt; choose 'Always Allow'."
security find-identity -v -p codesigning | grep "$NAME"
```

- [ ] **Step 3: Write `scripts/bundle.sh`**

```bash
#!/usr/bin/env bash
# Builds the Scribe executable, wraps it in build/Scribe.app, signs it, and
# launches it. Usage: scripts/bundle.sh [debug|release] [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
IDENTITY="${SCRIBE_SIGN_IDENTITY:-Scribe Dev}"
APP="build/Scribe.app"
BUNDLE_ID="com.jacobmarchionda.scribe"

swift build -c "$CONFIG" --product Scribe
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Scribe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Scribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  echo "warning: no '$IDENTITY' identity found; ad-hoc signing." >&2
  echo "         Audio permission will re-prompt after every rebuild. Run scripts/make-dev-cert.sh." >&2
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo "Built $APP"
if [[ "${2:-}" != "--no-open" ]]; then
  pkill -x Scribe 2>/dev/null || true
  open "$APP"
fi
```

Then: `chmod +x scripts/*.sh`

- [ ] **Step 4: Write `Sources/Scribe/MenuBarIcon.swift`**

```swift
import AppKit

/// Status item images. Idle is a template (adapts to menu bar theme);
/// recording is a red filled circle, deliberately not a template.
enum MenuBarIcon {
    static func image(recording: Bool) -> NSImage {
        if recording {
            let base = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = base.withSymbolConfiguration(config) ?? base
            image.isTemplate = false
            return image
        }
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Scribe")!
        image.isTemplate = true
        return image
    }
}
```

- [ ] **Step 5: Write `Sources/Scribe/AppState.swift` (shell version)**

```swift
import AppKit
import Foundation
import Observation
import ScribeCore

@MainActor
@Observable
final class AppState {
    let session: RecordingSession

    init(session: RecordingSession = RecordingSession()) {
        self.session = session
    }

    var isRecording: Bool { session.isRecording }
    var recordingsDirectory: URL { session.store.directory }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDirectory)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 6: Write `Sources/Scribe/MenuView.swift` (shell version)**

```swift
import SwiftUI

struct MenuView: View {
    let state: AppState

    var body: some View {
        Button("Open Recordings Folder") { state.openRecordingsFolder() }
        Button("Quit Scribe") { state.quit() }
            .keyboardShortcut("q")
    }
}
```

- [ ] **Step 7: Replace `Sources/Scribe/ScribeApp.swift`**

```swift
import SwiftUI

@main
struct ScribeApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: appState)
        } label: {
            Image(nsImage: MenuBarIcon.image(recording: appState.isRecording))
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 8: Create the signing identity, build the bundle, launch**

Run:
```bash
scripts/make-dev-cert.sh
scripts/bundle.sh debug
```
Expected: `Built build/Scribe.app`, then a waveform icon appears at the right of the menu bar and no Dock icon appears. Clicking it shows "Open Recordings Folder" and "Quit Scribe". "Open Recordings Folder" opens `~/Music/Scribe` in Finder (creating it). ⌘Q from the menu quits.

Verify the signature is the stable identity:
```bash
codesign -dv build/Scribe.app 2>&1 | grep -E "Identifier|Authority"
```
Expected: `Identifier=com.jacobmarchionda.scribe` and `Authority=Scribe Dev`.

- [ ] **Step 9: Commit**

```bash
git add Resources/Info.plist scripts/make-dev-cert.sh scripts/bundle.sh Sources/Scribe
git commit -m "Add menu bar app shell, Info.plist, bundle and dev-cert scripts

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Wire recording into the menu: Start/Stop, timer, icon, errors, quit-while-recording

**Files:**
- Modify: `Sources/Scribe/AppState.swift`, `Sources/Scribe/MenuView.swift`

**Interfaces:**
- Consumes: `RecordingSession.start/stop/isRecording/elapsed`, `formatElapsed`, `ScribeError.userMessage`.
- Produces on `AppState`: `private(set) var lastError: ScribeError?`, `private(set) var elapsedText: String`, `func toggle()`, `func openPrivacySettings()`. Task 11 adds notification calls at the two marked points.

- [ ] **Step 1: Replace `Sources/Scribe/AppState.swift`**

```swift
import AppKit
import Foundation
import Observation
import ScribeCore

@MainActor
@Observable
final class AppState {
    let session: RecordingSession
    private(set) var lastError: ScribeError?
    private(set) var elapsedText = "0:00"
    private var timer: Timer?

    init(session: RecordingSession = RecordingSession()) {
        self.session = session
        session.onInterrupted = { [weak self] error, url in
            self?.recordingInterrupted(error, url: url)
        }
    }

    var isRecording: Bool { session.isRecording }
    var recordingsDirectory: URL { session.store.directory }

    /// Start if idle, stop if recording. Errors land in `lastError`.
    func toggle() {
        do {
            if session.isRecording {
                let url = try session.stop()
                stopTimer()
                recordingSaved(url)
            } else {
                lastError = nil
                try session.start()
                startTimer()
            }
        } catch {
            stopTimer()
            lastError = (error as? ScribeError) ?? .writeFailed(OSStatus((error as NSError).code))
        }
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDirectory)
    }

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }

    func quit() {
        if session.isRecording {
            try? session.stop()
            stopTimer()
        }
        NSApp.terminate(nil)
    }

    // MARK: - Hooks Task 11 fills in

    private func recordingSaved(_ url: URL) {
        // Task 11: notifier.recordingSaved(url)
    }

    private func recordingInterrupted(_ error: ScribeError, url: URL) {
        stopTimer()
        lastError = error
        // Task 11: notifier.recordingStopped(error)
    }

    // MARK: - Timer

    private func startTimer() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsedText = "0:00"
    }

    private func tick() {
        elapsedText = formatElapsed(session.elapsed())
    }
}
```

- [ ] **Step 2: Replace `Sources/Scribe/MenuView.swift`**

```swift
import ScribeCore
import SwiftUI

struct MenuView: View {
    let state: AppState

    var body: some View {
        if let error = state.lastError {
            Text(error.userMessage)
            if error == .permissionDenied {
                Button("Open System Settings…") { state.openPrivacySettings() }
            }
            Divider()
        }

        if state.isRecording {
            Button("Stop Recording") { state.toggle() }
            Text("Recording  \(state.elapsedText)")
        } else {
            Button("Start Recording") { state.toggle() }
        }

        Divider()
        Button("Open Recordings Folder") { state.openRecordingsFolder() }
        Button("Recording Permissions…") { state.openPrivacySettings() }
        Button("Quit Scribe") { state.quit() }
            .keyboardShortcut("q")
    }
}
```

"Recording Permissions…" is always present because, per Task 5's observation, a denied tap may silently record nothing rather than fail; this gives the user a way to fix it without an error ever appearing.

- [ ] **Step 3: Build, launch, and exercise**

Run: `scripts/bundle.sh debug`

Check, in order:
1. Click the icon, choose "Start Recording". On the very first run macOS prompts for System Audio Recording and Microphone for "Scribe". Allow both. (If the recording started before you answered, stop it and start again.)
2. The icon turns into a red filled circle. Reopen the menu: "Stop Recording" and "Recording  0:0N" are shown, and the counter advances while the menu is open.
3. Play music and talk for a few seconds, then "Stop Recording". Icon returns to the waveform.
4. Verify the file: `afinfo ~/Music/Scribe/*.wav | grep -E "Data format|estimated duration"` shows `2 ch, 48000 Hz, Int16` and the right duration. Play it: voice left, music right.
5. Start again, then ⌘Q / "Quit Scribe". Relaunch with `open build/Scribe.app` and confirm the last file in `~/Music/Scribe` plays to the end (header was finalized).

- [ ] **Step 4: Verify the permission-denied path**

In System Settings → Privacy & Security → Screen & System Audio Recording, turn Scribe OFF. Choose "Start Recording".
- If Task 5 observed outcome (a): the menu shows "Scribe needs System Audio Recording permission." and "Open System Settings…", and clicking it opens the right pane.
- If outcome (b): recording starts; stop it after a few seconds and confirm the right channel is silent, then use "Recording Permissions…" to turn Scribe back on.

Turn the permission back on and quit the app.

- [ ] **Step 5: Commit**

```bash
git add Sources/Scribe/AppState.swift Sources/Scribe/MenuView.swift
git commit -m "Wire Start/Stop, elapsed timer, icon state and errors into the menu

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Notifications

**Files:**
- Create: `Sources/Scribe/Notifier.swift`
- Modify: `Sources/Scribe/AppState.swift`

**Interfaces:**
- Produces: `@MainActor final class Notifier { init(); func requestAuthorization(); func recordingSaved(_ url: URL); func recordingStopped(_ error: ScribeError) }`.

`UNUserNotificationCenter` only works from a bundled app. That is one more reason the binary must always run through `scripts/bundle.sh`.

- [ ] **Step 1: Write `Sources/Scribe/Notifier.swift`**

```swift
import Foundation
import ScribeCore
import UserNotifications

/// Posts the two notifications Scribe sends: saved, and stopped-by-error.
@MainActor
final class Notifier {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func recordingSaved(_ url: URL) {
        post(title: "Recording saved", body: url.lastPathComponent)
    }

    func recordingStopped(_ error: ScribeError) {
        post(title: "Recording stopped", body: error.userMessage)
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
```

- [ ] **Step 2: Wire it into `Sources/Scribe/AppState.swift`**

Add a stored property and request authorization in `init`:
```swift
    private let notifier = Notifier()
```
At the end of `init(session:)`:
```swift
        notifier.requestAuthorization()
```
Replace the two hook bodies:
```swift
    private func recordingSaved(_ url: URL) {
        notifier.recordingSaved(url)
    }

    private func recordingInterrupted(_ error: ScribeError, url: URL) {
        stopTimer()
        lastError = error
        notifier.recordingStopped(error)
    }
```

- [ ] **Step 3: Build, launch, verify**

Run: `scripts/bundle.sh debug`
Expected: on first launch macOS asks whether Scribe may send notifications; allow. Start and stop a short recording: a "Recording saved" notification appears with the filename. If nothing appears, open System Settings → Notifications → Scribe and confirm alerts are allowed.

- [ ] **Step 4: Commit**

```bash
git add Sources/Scribe/Notifier.swift Sources/Scribe/AppState.swift
git commit -m "Post notifications when a recording is saved or interrupted

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Stop cleanly when the default input device changes

**Files:**
- Create: `Sources/ScribeCore/DefaultInputWatcher.swift`
- Modify: `Sources/ScribeCore/LiveCapture.swift`

**Interfaces:**
- Consumes: `InterruptionRelay.fire(_:)`.
- Produces: `final class DefaultInputWatcher { init(onChange: @escaping @Sendable () -> Void); func start() throws; func stop() }` (internal). `onChange` runs on the main queue.

- [ ] **Step 1: Write `Sources/ScribeCore/DefaultInputWatcher.swift`**

```swift
import CoreAudio
import Foundation

/// Calls `onChange` on the main queue whenever the system default input
/// device changes (headset unplugged, AirPods connected, ...).
final class DefaultInputWatcher {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init(onChange: @escaping @Sendable () -> Void) {
        block = { _, _ in onChange() }
    }

    func start() throws {
        guard !installed else { return }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        guard status == noErr else { throw ScribeError.captureStartFailed(status) }
        installed = true
    }

    func stop() {
        guard installed else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        installed = false
    }

    deinit {
        stop()
    }
}
```

- [ ] **Step 2: Integrate into `LiveCapture`**

In `Sources/ScribeCore/LiveCapture.swift`, add a stored property after `relay`:
```swift
    private let watcher: DefaultInputWatcher
```
At the end of `init(url:)`, after `self.engine = ...`:
```swift
        let relay = self.relay
        self.watcher = DefaultInputWatcher {
            relay.fire(.inputDeviceChanged)
        }
```
Note: `self.relay` must be read into a local before the closure because `self` is not yet fully initialized. Move `private let relay = InterruptionRelay()` above `watcher` so it is initialized first (property initializers run before `init` body).

Change `start()`:
```swift
    func start() throws {
        try engine.start()
        try watcher.start()
    }
```
Change `stop()` and `deinit` to stop the watcher first:
```swift
    func stop() throws {
        watcher.stop()
        engine.stop()
        defer {
            aggregate = nil
            tap = nil
        }
        try writer.close()
    }

    deinit {
        watcher.stop()
        engine.stop()
        try? writer.close()
        aggregate = nil
        tap = nil
    }
```

- [ ] **Step 3: Run the unit tests (nothing should change)**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 4: Verify with the CLI**

Run: `swift build 2>&1 | tail -1 && .build/debug/scribe-cli record 30 /tmp`
While it records, change the default input device: plug in or unplug a USB mic or headset, connect AirPods, or switch the input in System Settings → Sound → Input.
Expected: within a second the CLI exits with `interrupted: The microphone changed, so the recording was stopped. (partial file at /tmp/... Recording.wav)` and that file plays back up to the point of the change.

- [ ] **Step 5: Verify in the app**

Run: `scripts/bundle.sh debug`, start a recording, switch the input device as above.
Expected: icon returns to the waveform, a "Recording stopped" notification shows the mic-changed message, and the menu shows the same message above "Start Recording".

- [ ] **Step 6: Commit**

```bash
git add Sources/ScribeCore/DefaultInputWatcher.swift Sources/ScribeCore/LiveCapture.swift
git commit -m "Stop and save when the default input device changes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: Smoke test checklist and README

**Files:**
- Create: `docs/smoke-test.md`, `README.md`

- [ ] **Step 1: Write `docs/smoke-test.md`**

```markdown
# Scribe manual smoke test

Run after any change to `ScribeCore` capture code or the app target. Unit
tests do not cover the audio path, so this is the only check that it works.

Setup: `scripts/make-dev-cert.sh` once, then `scripts/bundle.sh debug`.

## CLI capture path

1. Play music. Run `.build/debug/scribe-cli record 10 /tmp` and talk into the mic.
2. `afinfo /tmp/*Recording*.wav | grep "Data format"` shows `2 ch, 48000 Hz, Int16`.
3. Open the file: left channel is voice only, right channel is music only.

## App

4. Start Recording: icon turns red; reopening the menu shows Stop Recording and a ticking timer.
5. Stop Recording: icon returns to the waveform, "Recording saved" notification names the file, file is in `~/Music/Scribe` and plays with voice left / music right.
6. Open Recordings Folder opens `~/Music/Scribe` in Finder.
7. Start, then Quit Scribe: relaunch and confirm the last file plays to the end.
8. Start, then switch input devices (unplug headset / switch in Sound settings): recording stops, "Recording stopped" notification explains why, menu shows the message, partial file plays.

## Permissions

9. Turn Scribe off under System Settings → Privacy & Security → Screen & System Audio Recording, then Start Recording:
   - If tap creation fails: menu shows "Scribe needs System Audio Recording permission." and "Open System Settings…" opens the right pane.
   - If tap creation succeeds anyway (known Core Audio behavior): the right channel is silent. Use "Recording Permissions…" to re-enable. Detecting this at start time is a phase 1.5 item.
10. Turn the permission back on.

## Known gaps (phase 1.5)

- A crash mid-recording leaves a WAV with an unfinished header.
- Input device hot-swap stops the recording instead of continuing.
- No global hotkey, no input device picker, no launch at login, no app icon.
```

- [ ] **Step 2: Write `README.md`**

```markdown
# Scribe

A macOS menu bar app that records meetings: all system audio plus the default
microphone, saved as one stereo WAV (left = mic, right = system) in
`~/Music/Scribe/`. Fully local. Transcription and diarization are planned as
phase 2.

Requires macOS 14.2 or later.

## Build and run

```bash
scripts/make-dev-cert.sh   # once: self-signed "Scribe Dev" signing identity
scripts/bundle.sh          # build release, assemble build/Scribe.app, sign, launch
scripts/bundle.sh debug    # same, debug build
```

Always launch from `build/Scribe.app`. The bare binary in `.build/` has no
bundle, so permissions and notifications will not work.

## Test

```bash
swift test                 # unit tests (no audio hardware needed)
```

See `docs/smoke-test.md` for the manual checks that cover actual capture.

## Command line

```bash
swift build
.build/debug/scribe-cli tap                    # create a system audio tap, print its format
.build/debug/scribe-cli devices                # build the mic + tap aggregate, print its layout
.build/debug/scribe-cli record 10 /tmp         # record 10 s to /tmp
```

## Layout

- `Sources/ScribeCore` capture pipeline and recording state machine, no UI
- `Sources/Scribe` SwiftUI menu bar app
- `Sources/scribe-cli` headless recorder for spikes and smoke tests
- `docs/superpowers/specs` design docs
```

- [ ] **Step 3: Run the full smoke test once against the release build**

Run: `scripts/bundle.sh` (release) and walk through `docs/smoke-test.md` steps 1 to 10. Every step must pass.

- [ ] **Step 4: Commit**

```bash
git add docs/smoke-test.md README.md
git commit -m "Add README and manual smoke test checklist

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Done when

- `swift test` passes with all seven suites.
- `scripts/bundle.sh` produces a signed `build/Scribe.app` whose authority is "Scribe Dev".
- Every step in `docs/smoke-test.md` passes on the dev machine.
