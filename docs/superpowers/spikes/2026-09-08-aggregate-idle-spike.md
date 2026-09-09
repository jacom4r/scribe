# Spike: why the Scribe aggregate emits no IO callbacks while nothing is playing

**Date:** 2026-09-08 · **Machine:** macOS 26.6, Swift 6.3 CLT · **Status:** answered, root cause identified, fix validated

Throwaway investigation. No repo code was changed. All scratch code lives in
`/private/tmp/claude-502/-Users-jacob-marchionda-Documents-scribe/f2904984-4a30-4515-80aa-4231f0fa8b53/scratchpad/aggspike/`
(`spike.swift`, `rawmic.swift`). Every Core Audio call succeeded under the default Bash sandbox;
`dangerouslyDisableSandbox: true` was used once (a control run of `rawmic`) and changed nothing.

## Method

One standalone Swift program builds a `CATapDescription(monoGlobalTapButExcludeProcesses: [])`
tap plus an aggregate device from a configurable dictionary, installs an IO proc with
`AudioDeviceCreateIOProcIDWithBlock`, then counts callbacks over a 5 s silent window followed by a
5 s window with `afplay -v 0.15 /System/Library/Sounds/Ping.aiff` looping in the background. It also
records per-buffer peaks and how many callbacks carried an all-zero tap buffer. Devices are chosen
explicitly by UID; the user's default input and output devices were never changed.

## Device inventory found on this machine

```
id=127  in=[1] out=[]  48000 Hz  transport=ccwd            JacoPhone Microphone      (Continuity)
id=112  in=[]  out=[2] 48000 Hz  transport=hdmi            DELL S2725QS
id=108  in=[2] out=[]  16000 Hz  transport=usb             Logi Webcam C920e
id=79   in=[2] out=[2] 48000 Hz  transport=virt            BlackHole 2ch
id=96   in=[1] out=[]  48000 Hz  transport=bltn DEFAULT-IN MacBook Pro Microphone    (BuiltInMicrophoneDevice)
id=101  in=[]  out=[2] 48000 Hz  transport=bltn DEFAULT-OUT MacBook Pro Speakers     (BuiltInSpeakerDevice)
id=53   in=[]  out=[2] 48000 Hz  transport=grup            Scribe Output (stacked)
```

**Environment drift since task 7:** the AirPods Pro are gone; the current default input is the
**built-in MacBook Pro Microphone** (48 kHz, `bltn`), and the default output is the built-in speakers.
So experiment B (built-in mic) is the same device as experiment A (default input) — which by itself
already answers one question: **the stall is not Bluetooth-specific**. It reproduces identically on a
plain built-in 48 kHz mic.

## Results

Callback counts, 5 s windows unless noted. "silent" = nothing playing; "playing" = Ping.aiff looping.

| # | Configuration | Mic | Silent | Playing |
|---|---|---|---|---|
| A | Repo dictionary verbatim (main sub = mic drift 0, tap drift 1, private, TapAutoStart 1) | Built-in (= current default in) | **0** | 450 |
| B | Same dictionary, mic selected explicitly as built-in | Built-in | **0** | 450 (identical to A — same device) |
| C | A + `kAudioAggregateDeviceClockDeviceKey = micUID` | Built-in | **0** | 451 |
| D | Drift flags swapped: mic drift 1, tap drift 0 | Built-in | **0** | 443 |
| E | Tap-only aggregate (no sub-device list, no main sub-device) | — | **0** | 455 |
| F | A + **keepalive**: our process runs an IO proc on the default *output* device writing zeros, started before the aggregate | Built-in | **463** | 469 |
| G | F, but tap created with our own process object excluded | Built-in | **0** | 445 |
| I | A + default output device added as a second **sub-device**, aggregate IO proc zeroes its output buffers | Built-in | **0** | 449 |
| J | A + default output device as a second sub-device, output buffers untouched | Built-in | **0** | 444 |
| K | A, no keepalive for 5 s, then keepalive started **late**, still silent | Built-in | **0**, then **577** after keepalive | n/a |
| L | F, but the keepalive runs on a **non-default** output device (BlackHole 2ch) | Built-in | **462** | 470 |
| F′ | F re-run with 12 s windows (stability) | Built-in | **1119** | 1125 |

H (`TapAutoStart = 0`) was not needed: F already solves it.

Every callback delivers 2 input buffers (mic 1 ch, tap 1 ch) at 512 frames. In F′, 1119 callbacks ×
512 frames over 12 s = 47.7 k frames/s against the aggregate's nominal 48000 Hz — i.e. the device
runs at real time on the **mic's** timeline, continuously, with nothing playing.

In F and F′ the tap buffer was all zeros on **every** silent-phase callback (`zeroTapCbs == calls`:
463/463 and 1119/1119), and non-zero only when Ping actually played. The keepalive therefore adds no
audible content to the system channel — our zeros mix to zero.

## Clock-device readout (config A, and the others)

```
agg rate=48000.0  inputStreams=[1, 1]
kAudioDevicePropertyClockDevice              = <empty string>
kAudioAggregateDevicePropertyMainSubDevice   = BuiltInMicrophoneDevice
kAudioAggregateDevicePropertyClockDevice     = <empty string>
```

So the aggregate *does* report the mic as main sub-device, and reports **no** explicit clock device.
Adding `kAudioAggregateDeviceClockDeviceKey` (config C) makes both `kAudioDevicePropertyClockDevice`
and `kAudioAggregateDevicePropertyClockDevice` read back `BuiltInMicrophoneDevice` — the property is
honored — **and changes nothing about the stall** (still 0 callbacks in silence). In the tap-only
aggregate (E) all three read empty.

## What is actually going on

A global process tap has no timeline of its own: it is driven by the audio the tapped processes
produce. When **no process anywhere is running an output IO stream**, the tap is idle, and an
aggregate that contains a tap does not run its IO proc *at all* — even though a real, independently
clocking sub-device (the mic) is present and named as main sub-device. Evidence:

- E: a tap alone never clocks in silence, so the tap contributes no timeline.
- A/B/C/D: neither the main-sub-device key, an explicit clock-device key, nor either drift-compensation
  arrangement makes the mic's clock drive the aggregate. The tap gates the whole device.
- Task 7's `rawmic` result (and this spike's rerun): the bare mic device clocks fine in silence
  (376 callbacks in 4 s), so the mic is not the problem.
- F vs G is the decisive pair: making **our own process** produce output IO (a stream of zeros)
  un-gates the aggregate; excluding our own process from the tap re-gates it. The tap is watching for
  tappable process audio, and our silence counts.
- L: the keepalive works even on an output device that is *not* the default output, so the trigger is
  "this process is doing output IO that the tap can see", not "audio reached the tapped device".
- I/J: folding the keepalive into the aggregate itself cannot work — it is circular. The aggregate's
  output buffers can only be filled from its own IO proc, which is exactly what is not being called.
  The keepalive must be a **separate** device's IO proc.
- K: the keepalive also *rescues* an already-started, stalled aggregate; callbacks begin within the
  same window it is started. Nothing needs to be torn down and rebuilt.

## Recommendation

**Config F.** Keep `AggregateDevice`'s dictionary essentially as it is — none of the dictionary-level
variants (C, D, E, I, J) helps — and add a small always-on **silent output keepalive** to the capture
path. That is the only configuration tested that yields continuous callbacks during silence while the
mic remains the timeline (main sub-device = mic, aggregate rate = mic rate, tap drift-compensated).

Concretely:

1. **New type, e.g. `Sources/ScribeCore/OutputKeepAlive.swift`.** On `start()`: resolve the current
   default output device, `AudioDeviceCreateIOProcIDWithBlock` on it with a block that `memset`s every
   output buffer to zero, then `AudioDeviceStart`. On `stop()`/`deinit`: `AudioDeviceStop` +
   `AudioDeviceDestroyIOProcID`. ~40 lines, no dependencies on the rest of ScribeCore.
2. **Ownership:** `CaptureEngine` creates and starts it **before** `AudioDeviceStart` on the aggregate,
   and stops it after `AudioDeviceStop` (K shows late start also works, so ordering is a nicety, not a
   correctness requirement). Keeping it inside `CaptureEngine` rather than `AggregateDevice` is
   preferable: it is a *run-time* concern, not part of the device's composition, and `AggregateDevice`
   stays a pure builder.
3. **Do not change `ProcessTap`.** `monoGlobalTapButExcludeProcesses: []` must keep including our own
   process — G proves that excluding ourselves breaks the mechanism.
4. **Optional, cosmetic:** adding `kAudioAggregateDeviceClockDeviceKey: micUID` (config C) makes the
   clock explicit and readable back from the device. It fixes nothing, but it documents intent and
   costs nothing. Take it or leave it.

**Cost of the keepalive:** one extra IO proc (~93 callbacks/s, a `memset` of 512×2 floats each — noise
against the recording path), and it keeps the output device powered and "in use" for the duration of a
recording. On built-in speakers that is invisible. On AirPods it means the earbuds stay awake for the
whole meeting (battery, and the in-use indicator stays lit) — acceptable for a recorder that is
running anyway, but worth a mention in user-facing docs. It emits pure digital silence, so nothing is
audible and, as measured, the tap buffer stays exactly zero.

## Caveats

- **Mic signal was digital silence throughout this spike.** Every run, including the bare-device
  `rawmic` control (sandboxed *and* unsandboxed), reported mic peak exactly `0.0`. This is the same
  symptom as task 7's Concern B and is almost certainly TCC: these ad-hoc `swiftc` binaries have no
  microphone consent of their own, so macOS feeds them silence. It does not affect any conclusion here
  (this spike measures *whether callbacks happen*, not what is in them), but **the fix must still be
  confirmed by ear**: run a real recording with the keepalive and check that leading mic speech before
  any system audio is present and intelligible.
- **Bluetooth untested this session.** The AirPods Pro were not connected, so the Bluetooth warm-up
  behaviour from task 7 could not be re-examined. What *is* now established is that the stall is not
  Bluetooth-related: it reproduces on the built-in 48 kHz mic.
- **Sample rate follows the mic**, as before: 48 kHz here, 24 kHz when AirPods were default. `WavWriter`
  already resamples to 48 kHz, so this is only a note, not an issue.
- **Default output device can change mid-recording.** The keepalive binds to whatever the default
  output was when it started. Per L, it keeps working on a non-default device, so a mid-recording switch
  is harmless as long as the original device still exists — but if that device is *removed* (AirPods
  disconnect, dock unplugged) the keepalive dies and the aggregate stalls again. Worth a listener on
  `kAudioHardwarePropertyDefaultOutputDevice` (and/or device-removal) that restarts the keepalive on the
  new default; K shows a late restart recovers a stalled aggregate immediately.
- **Anything Scribe itself plays is captured**, since the tap deliberately does not exclude our process.
  Today that is only zeros. If Scribe ever plays real audio (a start/stop chime, playback of a previous
  recording) it will land in the system channel.
