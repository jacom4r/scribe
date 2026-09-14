# Scribe Phase 1.5: Input Device Hot-Swap

**Date:** 2026-09-14
**Status:** Approved design, pending implementation plan

## Goal

When the default input device changes mid-recording, keep recording instead of
stopping. The recording continues into the same WAV file, across a mic with a
different channel count and a different sample rate, with the gap in capture
padded so the file's duration still matches wall-clock time.

Today this case ends the recording: `LiveCapture`'s input watcher fires
`.inputDeviceChanged`, `RecordingSession.handleInterruption` stops and saves,
and the user gets a notification. After a week of daily use this is the only
complaint about phase 1, and it is the sole subject of this spec. The other six
phase 1.5 items — WAV header repair, global hotkey, input device picker, launch
at login, app icon, start-time permission detection — are independent and each
get their own cycle.

## Decisions already made

| Decision | Choice | Why |
|---|---|---|
| Swap policy | Follow the system default input wherever it goes | Matches what phase 1 already does at start time. A pinned-device mode belongs with the input device picker, not here. |
| Capture gap | Pad with silence to wall-clock elapsed time | File duration stays equal to real elapsed time, so phase 2 transcription and diarization timestamps remain true. Concatenating instead would shift everything after a swap earlier, compounding per swap. |
| Rate changes | `WavWriter` pins its file client format at 48 kHz and owns an `AudioConverterRef` | Forced by the spike: `ExtAudioFile` refuses a client format change mid-file, and an aggregate's nominal rate cannot be overridden. See below. |
| Structure | Extract the rebuildable graph behind a protocol | Swap correctness is the whole feature and needs unit tests; today nothing below `AudioCapturing` can be faked. |
| Failure behavior | Every failure path falls back to stop-and-save | A broken swap is then never worse than current behavior. |
| Visibility | Menu shows the mic currently being recorded | Glanceable, and silent during meetings. No notification on swap. |

Rejected alternatives:

- **Mutating the live aggregate** via `kAudioAggregateDevicePropertyFullSubDeviceList`
  to exchange the mic sub-device without teardown. It would shrink the gap, but
  changes the clock master and the buffer list's shape underneath a running IO
  proc, and is the least-documented of the options. Since the gap is padded, its
  length is comfort rather than correctness — not worth the risk. Available later
  as an optimization if swaps prove disruptive in practice.
- **Stopping when only the sample rate changes.** Disproved by the spike: the
  current default input is AirPods Pro locked to 24 kHz and the built-in mic runs
  48 kHz, so the headline swap crosses rates every time. This fallback would fire
  in exactly the case it was meant to avoid.

## What the spike established

Full report: `docs/superpowers/spikes/2026-09-14-extaudiofile-rate-change-spike.md`.

1. `kExtAudioFileProperty_ClientDataFormat` cannot be re-set once any audio has
   been written — `-66565` `kExtAudioFileError_InvalidOperationOrder`, on both the
   sync and the async write paths.
2. An aggregate device's nominal sample rate cannot be forced. Setting it returns
   `'nope'` (`kAudioHardwareIllegalOperationError`); the aggregate advertises only
   the rates its main sub-device supports.
3. AirPods Pro support 24 kHz and nothing else. Rate changes across a swap are the
   normal path, not an edge case.

## Architecture

One new file, `Sources/ScribeCore/CaptureGraph.swift`, holding the part that is
rebuilt on each swap: an `AggregateDevice` plus the `CaptureEngine` driving it,
built around a tap and a writer it does not own.

```
LiveCapture                     (long-lived, one per recording)
├── ProcessTap                  created once, reused across swaps
├── WavWriter                   one file, fixed 48 kHz client format
├── InterruptionRelay
├── OutputKeepAlive
├── DefaultDeviceWatcher .input  -> swap policy
├── DefaultDeviceWatcher .output -> keepalive restart (unchanged)
└── graph: any InputGraph       rebuilt on every swap
    ├── AggregateDevice         mic + tap, layout, sampleRate
    └── CaptureEngine           IO proc -> downmix -> writer
```

The tap is created once and reused. Its UID stays valid as long as the object
lives, so a new `AggregateDevice` can be built around the same tap. A swap
therefore never re-creates the tap and never re-touches the System Audio
permission.

Two protocols make the swap testable:

```swift
protocol InputGraph: AnyObject {
    var micName: String { get }
    var sampleRate: Double { get }
    func start() throws
    func stop()
}

protocol InputGraphBuilding {
    func makeGraph() throws -> any InputGraph
}
```

`LiveCapture` holds a builder and the current graph. Tests drive the swap with a
fake builder that records calls and can be made to fail; no hardware, no
permissions.

`AggregateDevice` itself is unchanged. It already resolves the current default
input at init and recomputes `layout` from the new mic's stream counts, which is
exactly what a rebuild needs.

## Swap sequence

Triggered by the input watcher, which today calls `relay.fire(.inputDeviceChanged)`
and will instead call into the swap policy. Everything below runs on the main
queue, so swaps cannot overlap.

1. **Filter.** Resolve the current default input. If it is the same device the
   current graph is already on, return — the watcher fires on any change to the
   property, including ones that resolve back to the same device.
2. **Coalesce.** Wait ~300 ms and re-resolve before acting. Connecting AirPods can
   emit several notifications in a row, and each rebuild costs a real gap. The
   window is fixed from the first notification and is **not** extended by later
   ones: a device that flaps continuously would otherwise postpone the swap
   indefinitely, leaving the recording on a mic that is already gone.
3. **Stop.** `graph.stop()`. `CaptureEngine.stop()` is synchronous and returns only
   once Core Audio has torn the proc down, so no `writeAsync` is in flight
   afterward. Record the gap start from a monotonic clock.
4. **Rebuild.** `builder.makeGraph()`. The new `AggregateDevice` picks up the new
   default input and computes a fresh `layout`.
5. **Retune.** If the new graph's `sampleRate` differs from the writer's current
   input rate, `writer.setInputSampleRate(_:)`.
6. **Pad.** `writer.writeSilence(duration:)` for the measured gap.
7. **Start.** `graph.start()`.
8. **Publish.** Report the new `micName` on the main queue.

Steps 4, 5 and 7 can each throw. Any throw falls back to stop-and-save: fire the
relay once, which routes through the existing `RecordingSession.handleInterruption`
path and keeps the partial file.

### Gap accounting

The gap is measured from step 3 to just before step 7 and padded in step 6.
Silence must be written before the new engine starts, because once it starts it
writes from the real-time thread and ordering would no longer be deterministic.

The residual error is the IO proc's own start latency inside `AudioDeviceStart`,
which is genuine dead time but cannot be measured from our side. It is bounded and
small relative to the teardown and rebuild it follows. This is documented rather
than papered over; the spec does not claim the padding is exact.

`writeSilence` goes through the existing primed async path with a zeroed 48 kHz
buffer, chunked to stay under the async ring buffer limit — the spike hit
`kExtAudioFileError_AsyncWriteTooLarge` writing a full second at once, and a long
Bluetooth swap could produce a comparable span. It is called only while no IO proc
is running.

## WavWriter changes

Today the writer sets its client format from `inputSampleRate` at init and lets
`ExtAudioFile` resample to the 48 kHz file format. Since that property is immutable
once written, the writer takes ownership of the conversion instead:

- The `ExtAudioFile` client format is **fixed at 48 kHz** for the life of the file.
- An internal `AudioConverterRef` converts from the current input rate to 48 kHz.
- `setInputSampleRate(_:)` rebuilds that converter. When the new rate equals the old
  one it is a no-op.
- `writeSilence(duration:)` writes zeroed 48 kHz frames directly, bypassing the
  converter — silence needs no resampling, and this keeps gap length exact and
  independent of whichever mic is attached.
- `inputSampleRate` becomes `private(set)` state rather than an init-only constant.

Both new methods carry the same precondition as the existing `close()`: **the caller
must have stopped the engine first.** That contract is already spelled out in the
header comment on `WavWriter` and justifies its `@unchecked Sendable`; these methods
extend it rather than introducing a new rule. `CaptureEngine.stop()` being
synchronous is what makes it satisfiable.

Real-time implications, and the reason this is the most delicate part of the change:

- `AudioConverterFillComplexBuffer` must be primed during `prime()`, not on the
  first callback, so that no allocation happens on the audio thread.
- Conversion output is variable-size — 24 kHz to 48 kHz doubles the frame count.
  The writer needs an internal output buffer sized for the worst-case supported
  ratio, where today it implicitly assumes 1:1.
- The converter is rebuilt only from the main thread between a stop and a start,
  so the real-time thread never observes it changing.

`CaptureEngine` and `IOState` are unchanged: the engine still calls
`writer.writeAsync(frames:bufferList:)` with downmixed interleaved stereo, and the
conversion happens inside the writer.

## Menu

- `AudioCapturing` gains `var micName: String { get }` and
  `var onInputChanged: (@Sendable (String) -> Void)?`.
- `RecordingSession` gains an observable `public private(set) var micName: String?`,
  set on start and updated on swap.
- `AppState` exposes it; `MenuView` renders it as its own line beneath the timer, so
  the existing `Recording <elapsed>` line stays short in the dropdown.

No notification fires on a successful swap. A swap is the feature working; a device
that flaps would otherwise notify repeatedly during a meeting.

## Error handling

This table supersedes the "Default input changes mid-recording" row of the phase 1
spec, which reads "Session stops and saves what it has. Hot-swap is out of scope."

| Situation | Behavior |
|---|---|
| Default input changes to a different device | Coalesce, rebuild, pad, continue. Menu mic name updates. No notification. |
| Watcher fires but the default resolves to the same device | Ignored. No rebuild, no gap. |
| Several changes in a burst | One rebuild, one gap. |
| Last input device removed, no replacement | `CoreAudio.defaultInputDevice()` throws. Stop and save with `.inputDeviceChanged`, as today. |
| New aggregate fails to build | Stop and save. Partial file kept. |
| `setInputSampleRate` fails | Stop and save. |
| New engine fails to start | Stop and save. |
| Write failure during or after a swap | Unchanged: relay fires `.writeFailed`, session stops and saves. |
| Default output changes during a swap | Unchanged: keepalive restarts independently. |
| User stops recording mid-swap | Steps 3-8 run as one unit on the main queue, so `stop()` is serviced either fully before or fully after; both are safe. |
| User stops recording during the coalescing window | `LiveCapture.stop()` and `deinit` cancel any pending swap before tearing down the graph, so the timer cannot fire against a closed writer. |

Every failure fires the relay exactly once — `InterruptionRelay` already enforces
at-most-one delivery — so a swap that fails partway cannot produce two
notifications.

## Testing

Unit tests, no hardware and no permissions, consistent with the existing suite.

`InputSwapTests` (new), driving `LiveCapture`'s swap policy with a fake
`InputGraphBuilding`:

- A default-input change to a different device rebuilds the graph.
- The old graph is stopped before the new one is built.
- A change that resolves to the same device does not rebuild.
- A burst of changes produces exactly one rebuild.
- A builder failure fires exactly one interruption and stops the session.
- A start failure on the new graph fires exactly one interruption.
- A new graph with a different `sampleRate` triggers `setInputSampleRate`; an
  identical rate does not.
- `stop()` during the coalescing window cancels the pending swap: no graph is
  built and the writer is not touched after close.

`WavWriterTests` (extended):

- `writeSilence(duration:)` adds exactly `duration × 48000` frames, rounded, and
  those frames read back as zero on both channels.
- A 24 kHz to 48 kHz round trip: write a known tone at 24 kHz, read back at 48 kHz,
  assert the output frame count doubles and the tone survives.
- `setInputSampleRate` mid-file, then write, then close: the file is valid, the
  frame count is the sum of both segments converted, and content on both sides of
  the change is intact. This is the assertion the spike could not make about the
  original mechanism.

`RecordingSessionTests` (extended):

- The session stays `.recording` across a swap.
- `micName` updates on swap.
- A failed swap leaves the session `.idle` and calls `onInterrupted` once.

Manual checks added to `docs/smoke-test.md`:

- Start on AirPods, disconnect them mid-recording, confirm the recording continues
  on the built-in mic, the menu name updates, and the file has a short silence
  rather than ending. This is the 24 kHz to 48 kHz path.
- Start on the built-in mic, connect AirPods mid-recording, confirm the reverse.
- Unplug a USB mic mid-recording.
- For each: file duration is within a second of wall-clock recording time, and both
  channels still carry audio after the swap.

The smoke test's existing "Known gaps (phase 1.5)" entry for hot-swap is removed
when this ships.

## Out of scope

- The other six phase 1.5 items, each of which is independent of this one.
- A pinned input device or manual device selection — that arrives with the input
  device picker.
- Live sub-device mutation as a gap optimization.
- Any change to `OutputKeepAlive`, the tap, the downmix, or the file format.
- Output device hot-swap, which already works.
