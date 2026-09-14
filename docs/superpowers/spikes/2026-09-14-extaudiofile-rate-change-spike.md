# Spike: can an open WAV absorb a mid-recording sample rate change?

**Date:** 2026-09-14 · **Machine:** macOS 26.6.2, Swift 6.3.2 CLT · **Status:** answered, original mechanism disproved, replacement chosen

Throwaway investigation for the input hot-swap design. No repo code was changed. Scratch code lives in
`/private/tmp/claude-502/-Users-jacob-marchionda-Documents-scribe/ef3b73c9-dc0b-434d-bc69-5c9526cca79a/scratchpad/`
(`ratespike.swift`, `ratespike2.swift`, `ratespike3.swift`). No tap and no microphone input were used, so
no TCC consent was involved and none of the silence caveats from the aggregate idle-clock spike apply here.

## The question

Hot-swapping the input device mid-recording means the new mic may run at a different sample rate than the
old one. `WavWriter` fixes its `kExtAudioFileProperty_ClientDataFormat` from `inputSampleRate` at init and
lets `ExtAudioFile` resample to the 48 kHz file format. The proposed design re-set that property on the
open file after quiescing writes. Is that legal?

## Method

Three standalone Swift programs:

1. `ratespike.swift` — create a WAV, set client format to 48 kHz, write 1 s of 440 Hz sine, re-set the
   client format to 44.1 kHz, write 1 s of 880 Hz, dispose, read back with `AVAudioFile`. Run on both the
   synchronous (`ExtAudioFileWrite`) and asynchronous (`ExtAudioFileWriteAsync`) paths.
2. `ratespike2.swift` — the async path again, corrected: 512-frame chunks paced with `usleep` to match a
   real IO proc, because v1's one-second async writes exceeded the ring buffer.
3. `ratespike3.swift` — build a private aggregate on the default input (no tap) and try to force its
   nominal sample rate to 48 kHz, to see whether the rate problem can be avoided upstream instead.

## Results

| # | Path | Re-set client format mid-file | Readback |
|---|---|---|---|
| 1 | Sync, 1 s single write | **-66565** `kExtAudioFileError_InvalidOperationOrder` | n/a, aborted |
| 2 | Async, 1 s single write | 0 (meaningless) | 0 frames — every write had failed with **-66569** `kExtAudioFileError_AsyncWriteTooLarge` |
| 3 | Async, 512-frame paced chunks | **-66565** `kExtAudioFileError_InvalidOperationOrder` | 48000 frames = 1.0000 s, expected 96000 / 2.0000 s |

Run 2 is recorded only because its apparent success was an artifact: the oversized async writes all failed,
so nothing had been written and the format change was trivially accepted. Once run 3 wrote data the way
`CaptureEngine` actually does, the property change was refused exactly as on the sync path.

**`kExtAudioFileProperty_ClientDataFormat` cannot be changed once any audio has been written to the file.**
The refusal is not an ordering detail to work around; run 3's readback is one second long, not two, so the
post-change segment is simply absent.

### Can the aggregate be pinned to 48 kHz instead?

```
default input: Jacob's AirPods Pro #2  uid=EC-E9-D2-7A-A0-ED:input
  nominal rate: 24000.0
  supported:    24000

aggregate created (id 183)
  nominal rate: 24000.0
  supported:    24000
  set 48000: status 'nope' -> now 24000.0
  set 44100: status 'nope' -> now 24000.0
```

No. `AudioObjectSetPropertyData` on `kAudioDevicePropertyNominalSampleRate` returns `'nope'`
(`kAudioHardwareIllegalOperationError`, 1852797029), and the aggregate advertises only the rates its main
sub-device supports. The aggregate's rate follows the mic and cannot be overridden.

## The finding that drives the design

**The current default input is AirPods Pro running at 24 kHz, and 24000 is the only rate it supports.**
The built-in MacBook Pro microphone runs at 48 kHz. The headline hot-swap scenario — AirPods disconnect
mid-meeting, macOS falls back to the built-in mic — therefore crosses a sample rate boundary *every time*.

This rules out the tempting scope cut of "hot-swap only when the rate matches, otherwise stop and save as
today". That fallback would fire in the single most common case it was meant to avoid. Rate changes are
the normal path here, not an edge case.

(The aggregate idle-clock spike already noted this rate in passing, as "only a note, not an issue". For
phase 1 it was: one device, one rate, fixed at init. For hot-swap it is the central constraint.)

## Recommendation

Keep the conversion, but own it. `WavWriter` pins its `ExtAudioFile` client format to 48 kHz for the life
of the file and holds an internal `AudioConverterRef` that absorbs whatever rate the current mic delivers.
`setInputSampleRate(_:)` stays in the design as proposed and rebuilds that converter — legal, because the
converter is our object rather than `ExtAudioFile` state.

`CaptureEngine`'s real-time path keeps its current shape: it still calls
`writer.writeAsync(frames:bufferList:)` and the conversion happens inside the writer.

## Caveats

- **Resampling moves onto the real-time thread.** `AudioConverterFillComplexBuffer` does not allocate once
  configured, but it must be primed inside `prime()` rather than on first callback, and it produces a
  variable number of output frames — 24 k to 48 k doubles them. The writer's internal output buffer must be
  sized for the worst-case ratio instead of today's implicit 1:1.
- **Converter behavior on the async write path was not itself measured.** This spike disproved the original
  mechanism; it did not prove the replacement. The first implementation task should cover a 24 k to 48 k
  conversion feeding `ExtAudioFileWriteAsync` in realistic chunks, with a round-trip assertion on output
  frame count.
- **Only 48 k and 44.1 k were exercised for the format change.** 24 k was read from the device but never
  written, since the property refusal made the rate values irrelevant.
- **Aggregate rate-setting was tested with a single-device aggregate**, no tap, with AirPods as the only
  default input available at the time. A multi-sub-device aggregate was not tried, but since the refusal
  comes from the main sub-device's supported-rate list, that is unlikely to differ.
