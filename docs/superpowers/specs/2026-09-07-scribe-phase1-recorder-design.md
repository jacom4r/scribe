# Scribe Phase 1: Menu Bar Meeting Recorder

**Date:** 2026-09-07
**Status:** Approved design, pending implementation plan

## Goal

A native macOS menu bar app that records meetings. It captures all system
audio and the default microphone into a single stereo WAV file. Recording is
started and stopped manually from the menu bar. Transcription and diarization
are explicitly out of scope for this phase and will get their own spec.

## Decisions already made

| Decision | Choice | Why |
|---|---|---|
| Language / UI | Swift 6, SwiftUI `MenuBarExtra` | Native audio APIs and native menu bar UX. Phase 2 will call a Python sidecar. |
| Build | SwiftPM only, no Xcode.app | Fully scriptable; Xcode can open `Package.swift` later if wanted. |
| System audio capture | Core Audio process tap (`CATapDescription`) inside an aggregate device with the mic | One clock-aligned stream, drift handled by Core Audio, single honest permission prompt. |
| Output | One stereo WAV per recording, 48 kHz, 16-bit PCM. Left = mic (mono), right = system audio (mono). | Playable anywhere; phase 2 can split channels to separate "me" from "them". |
| Controls | Dropdown menu: Start/Stop, elapsed time, Open Recordings Folder, Quit | Discoverable and predictable. Hotkey deferred to phase 1.5. |
| Storage | `~/Music/Scribe/<yyyy-MM-dd HH-mm> Recording.wav` | User-visible, sortable. |
| Minimum macOS | 14.2 | First release with the process tap API. Dev machine runs 26.6. |

Rejected alternatives: ScreenCaptureKit audio (requires Screen Recording
permission, independent clock from mic, drift) and virtual audio drivers such
as BlackHole (third-party install, changes user's output routing).

## Repository layout

```
scribe/
  Package.swift
  Sources/
    ScribeCore/          # library, no UI
      ProcessTap.swift
      AggregateDevice.swift
      CaptureEngine.swift
      Downmix.swift
      WavWriter.swift
      RecordingSession.swift
      RecordingStore.swift
      ScribeError.swift
    Scribe/              # menu bar executable
      ScribeApp.swift
      AppState.swift
      MenuView.swift
      Notifications.swift
    scribe-cli/          # headless recorder for spikes and smoke tests
      main.swift
  Tests/ScribeCoreTests/
  Resources/
    Info.plist
    AppIcon.icns
  scripts/
    bundle.sh            # build, assemble Scribe.app, sign, launch
    make-dev-cert.sh     # one-time self-signed "Scribe Dev" certificate
  docs/
    superpowers/specs/
    smoke-test.md        # manual checklist for the capture path
```

`ScribeCore` has no AppKit or SwiftUI dependency. Both executables link it.

## Components

Each component has one job and a small public surface. Everything below the
session is `internal` to `ScribeCore`.

### ProcessTap

Wraps `CATapDescription` and `AudioHardwareCreateProcessTap` /
`AudioHardwareDestroyProcessTap`.

- Config: tap all processes (`CATapDescription(monoGlobalTapButExcludeProcesses: [])`), mixed to mono, private, unmuted (user still hears audio).
- API: `init() throws`, `var objectID: AudioObjectID`, `var uid: String`, `deinit` destroys the tap.
- Creating the tap is where macOS shows the system audio recording permission prompt on first use. Failure surfaces as `ScribeError.permissionDenied` when the OS status indicates TCC denial, otherwise `ScribeError.tapCreationFailed(OSStatus)`.

### AggregateDevice

Builds a private aggregate device via `AudioHardwareCreateAggregateDevice`.

- Sub-devices: the current default input device (mic). Tap list: the `ProcessTap` UID.
- Drift compensation enabled on the tap and the mic; the mic is the clock master.
- API: `init(tap: ProcessTap) throws`, `var deviceID: AudioDeviceID`, `var inputLayout: InputLayout` (which input channels are mic and which are tap), `var sampleRate: Double`, `deinit` destroys the device.
- `InputLayout` is a small value type: `micChannels: Range<Int>`, `systemChannels: Range<Int>`, `totalChannels: Int`. Derived by querying the aggregate's stream configuration after creation.

### Downmix

A pure function, no state, no allocation in the hot path:

```swift
func downmix(input: UnsafeBufferPointer<Float>, frames: Int,
             layout: InputLayout, into output: UnsafeMutableBufferPointer<Float>)
```

Output is interleaved stereo. Left is the mean of mic channels, right is the
mean of system channels. This is the most unit-testable piece of the audio
path and is kept separate for exactly that reason.

### WavWriter

Wraps `ExtAudioFile`.

- Opens a WAV at a URL with client format Float32 stereo at the aggregate's sample rate, file format 16-bit PCM stereo at 48 kHz. `ExtAudioFile` performs the conversion.
- `write(_:)` uses `ExtAudioFileWriteAsync`, which is safe to call from the real-time IO thread. `ExtAudioFileWriteAsync` must be primed once with a zero-length write from a non-real-time thread before the IO proc starts, per Apple's documentation.
- `close()` finalizes the header. Errors surface as `ScribeError.writeFailed(OSStatus)`.

### CaptureEngine

Installs an IO proc on the aggregate device with `AudioDeviceCreateIOProcID`,
starts and stops it.

- On each callback: run `downmix` into a preallocated scratch buffer, then `writer.write`. No allocation, no locks, no Swift concurrency hops on the audio thread.
- Also registers a listener for `kAudioHardwarePropertyDefaultInputDevice` changes. On change it signals the session (off the audio thread) that the device went away.

### RecordingSession

`@MainActor` state machine and the only public entry point in `ScribeCore`.

```
enum State { case idle, recording(since: Date, url: URL), finalizing }
```

- `start() async throws -> URL`: create tap, build aggregate, ask the store for a URL, open writer, start engine. Any failure unwinds fully back to `idle` and rethrows.
- `stop() async throws -> URL`: stop engine, close writer, destroy aggregate then tap, return the URL.
- Publishes `state` and `elapsed` (derived from `since`) via `@Observable`.
- Reacts to engine device-change and write-failure signals by calling `stop()` and reporting a `ScribeError` through an `onInterrupted` callback.

### RecordingStore

- `recordingsDirectory: URL` = `~/Music/Scribe/`, created on first use.
- `newRecordingURL(at date: Date) -> URL` producing `yyyy-MM-dd HH-mm Recording.wav`. If that name exists, append ` (2)`, ` (3)`, and so on.

### ScribeError

```
enum ScribeError: Error {
  case permissionDenied
  case tapCreationFailed(OSStatus)
  case aggregateCreationFailed(OSStatus)
  case noInputDevice
  case writeFailed(OSStatus)
  case inputDeviceChanged
}
```

Each case has a `userMessage` suitable for the menu and notifications.

### App target

- `ScribeApp`: `MenuBarExtra` with `.menu` style. `LSUIElement` keeps it out of the Dock.
- `AppState`: `@MainActor @Observable`, owns a `RecordingSession`, a one-second timer for the elapsed label, and the last error. Exposes `toggle()`, `openRecordingsFolder()`, `quit()`.
- `MenuView`: renders, from top to bottom:
  - Idle: "Start Recording", divider, "Open Recordings Folder", "Quit Scribe".
  - Recording: "Stop Recording", "Recording  12:34" (disabled label), divider, "Open Recordings Folder", "Quit Scribe".
  - Error: the error's `userMessage` as a disabled label, plus "Open System Settings" when the error is `permissionDenied`, above the normal idle items.
- Menu bar icon: SF Symbol `waveform` when idle, `record.circle.fill` tinted red while recording.
- `Notifications`: requests `UNUserNotificationCenter` authorization on first launch and posts "Recording saved" with the filename on stop, or "Recording stopped" with the error message on interruption.
- Quit while recording: `AppState.quit()` awaits `session.stop()` before calling `NSApp.terminate`.

### scribe-cli

`scribe-cli record <seconds> [output.wav]`. Drives `RecordingSession` headlessly, prints the output path, exits non-zero with the error message on failure. This is the phase 0 spike vehicle and the permanent manual smoke test.

## Data flow

Start: `MenuView` → `AppState.toggle()` → `RecordingSession.start()` →
`ProcessTap` (permission prompt on first use) → `AggregateDevice` →
`RecordingStore.newRecordingURL` → `WavWriter.open` → `CaptureEngine.start`
→ state becomes `.recording`, icon turns red, timer ticks.

Audio thread, per callback: aggregate input buffer → `downmix` → `WavWriter.write`.

Stop: `MenuView` → `AppState.toggle()` → `RecordingSession.stop()` →
`CaptureEngine.stop` → `WavWriter.close` → destroy aggregate → destroy tap →
state `.idle` → "Recording saved" notification.

## Permissions and packaging

`Resources/Info.plist`:

- `CFBundleIdentifier`: `com.jacobmarchionda.scribe`
- `NSAudioCaptureUsageDescription`: "Scribe records system audio so your meetings can be transcribed."
- `NSMicrophoneUsageDescription`: "Scribe records your microphone during meetings."
- `LSUIElement`: true
- `LSMinimumSystemVersion`: 14.2

`scripts/bundle.sh`: `swift build -c release`, copy the `Scribe` binary into
`build/Scribe.app/Contents/MacOS/`, copy `Info.plist` and icon, `codesign
--force --sign "Scribe Dev"`, then `open build/Scribe.app`.

`scripts/make-dev-cert.sh`: creates a self-signed code signing certificate
named "Scribe Dev" in the login keychain, once. macOS ties TCC grants to the
signing identity, so a stable certificate means the audio permission survives
rebuilds. Ad-hoc signing would re-prompt after every build.

The permission the user sees lives in System Settings → Privacy & Security →
Screen & System Audio Recording, under "System Audio Recording Only".

## Error handling

| Situation | Behavior |
|---|---|
| Audio permission denied | `start()` throws `permissionDenied`. Menu shows the message plus "Open System Settings". State stays idle. |
| No default input device | `start()` throws `noInputDevice`. Menu shows message. |
| Default input changes mid-recording | Session stops and saves what it has, notification explains why. Hot-swap is out of scope. |
| Write failure mid-recording | Session stops, keeps the partial file, notification carries the error. |
| Quit while recording | Stop and finalize before terminating. |
| App crash mid-recording | Known gap: WAV header is written on close, so the file needs header repair. Deferred to phase 1.5. |

## Testing

Unit tests in `Tests/ScribeCoreTests` (no hardware, no permissions):

- `DownmixTests`: known interleaved input with mic on channels 0 and 1 and tap on 2 and 3, assert left and right outputs equal the channel means; edge cases for mono mic and single-channel layouts.
- `RecordingStoreTests`: filename format, directory creation in a temp home, collision suffixing.
- `WavWriterTests`: write a generated sine on left and silence on right to a temp file, read back with `AVAudioFile`, assert 48 kHz, 2 channels, frame count, and channel contents.
- `RecordingSessionTests`: state transitions using a protocol-backed fake engine and writer, including unwind on failure and stop-on-interrupt.

Manual checks (documented in `docs/smoke-test.md`):

1. `scribe-cli record 10` with music playing and speaking into the mic. Open the WAV, confirm left has voice and right has music.
2. In the app: Start, confirm red icon and timer, Stop, confirm notification and file.
3. Deny permission in System Settings, Start, confirm the error line and settings link.
4. Unplug a USB mic mid-recording, confirm clean stop and notification.
5. Quit while recording, confirm the file is playable.

## Phase 0 spike (first task of the plan)

Before any app code: `scribe-cli record 10` produces a playable stereo WAV on
the dev machine with both channels populated. This validates the tap,
aggregate, downmix and writer together. If the tap or aggregate API behaves
unexpectedly, the spike is where that surfaces, and the design gets revised
before the app is built.

## Out of scope for phase 1

- Transcription and diarization (phase 2, separate spec)
- Global hotkey, input device picker, launch at login, WAV header repair (phase 1.5)
- Automatic meeting detection
- Distribution to other users, notarization
