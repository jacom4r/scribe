# Scribe Phase 2: Local Transcription and Diarization

**Date:** 2026-09-17
**Status:** Approved design, pending implementation plan

## Goal

When a recording stops, Scribe transcribes it on-device and writes a Markdown
transcript next to the WAV, with the user's own speech labelled "Me" and
everyone else labelled by speaker. No network after the one-time model
download, no Python, no new UI beyond a status line in the menu and two
notifications.

Phase 1 pencilled in a Python sidecar (WhisperX + pyannote). This spec replaces
that with FluidAudio, a Swift package that runs Parakeet TDT v2 and the
pyannote community-1 offline diarization pipeline as CoreML models on the
Neural Engine. The spike behind this choice is
`docs/superpowers/spikes/2026-09-16-fluidaudio-transcription-spike.md`.

## Decisions already made

| Decision | Choice | Why |
|---|---|---|
| Engine | FluidAudio, exact pin `0.15.7`, `traits: []` | Pure Swift, Apache 2.0, macOS 14, one SwiftPM dependency. The trait opt-out drops a 49 MB text-normalisation binary that only TTS uses. |
| ASR model | Parakeet TDT v2 (English only) | Meetings are English only. FluidAudio's docs and the spike both show v2 with higher recall than v3 on English. |
| Diarization | `OfflineDiarizerManager`, default config | Segmentation + WeSpeaker + VBx. Spike gave the right speaker counts on two real meetings. |
| Channels | Left channel is "Me", diarize the right channel only | The stereo split already separates the user from everyone else; diarizing a mono mix would throw that away and label the user "Speaker N". |
| Mic bleed | Ignored | User is on AirPods or headphones. Spike measured mic-to-system word overlap at chance level. |
| Tiny speaker clusters | Kept and labelled like any other speaker | User prefers over-inclusive. A background video in the office became a speaker on one call and that is acceptable. |
| Trigger | Automatic on every recording stop, including interruption stops | The only path the user will actually use. A manual "transcribe this WAV" item is deferred. |
| Output | `<same name>.md` next to the WAV, overwritten if present | Phase 2.5 adds a target folder picker. |
| Format | Speaker turns, no timestamps, header with filename, duration, speaker list | Approved sample below. Timestamps were dropped as noise. |
| Model download | At app launch, in the background, retried on the next enqueue if it fails | First transcript is not delayed by a 90 s download; an offline first launch heals itself on the next recording stop. |
| Concurrency | Jobs run one at a time in arrival order; recording is independent of transcription | ASR manager is a single actor. Capture runs on Core Audio's thread; ML is mostly Neural Engine. |
| Failure | WAV untouched, notification, menu line until the next success. No persisted retry queue | Same posture as phase 1: never lose the recording. |
| Structure | Pure logic in ScribeCore, FluidAudio adapter in a new `ScribeTranscription` target | ScribeCore tests stay hardware-free and model-free. |

## What the spike established

- The whole pipeline runs at 50 to 60x real time on the M5 Pro: 8 s for a 7 minute
  meeting, 72 s for 71 minutes. Warm model load is 0.2 s. First-run download and
  compile is about 90 s. Model cache is 472 MB under
  `~/Library/Application Support/FluidAudio/Models/`.
- Reading the whole 48 kHz file into memory before resampling is what drives
  peak memory (3.5 GB on the 71 minute file). The reader must stream.
- A naive time-ordered word merge shreds sentences whenever two people talk at
  once (89 single-word "Me" turns on one file). Phrase-first assembly fixed it
  (7 single-word turns). This is the turn assembler below.
- A silent mic channel yields zero words. A speech-free system channel makes
  the diarizer throw `OfflineDiarizationError.noSpeechDetected`. Both are
  normal inputs, not failures.
- The README's `transcribe(_:source:)` overload does not exist at 0.15.7. The
  batch entry point is `transcribe(_:decoderState:)` with a fresh
  `TdtDecoderState` per call. Words come from the public `buildWordTimings(from:)`.
- Mic gain normalisation before ASR made no difference and is not adopted.
- FluidAudio prints a benign Neural Engine warning (`E5RT ... slice_by_index:
  zero shape error`) to stderr at teardown. Expected; not a bug to chase.

## Architecture

```
Sources/ScribeCore            (no new dependencies)
  SpeechEngine.swift           protocol + TimedWord, SpeakerSegment
  ChannelReader.swift          stereo WAV -> two 16 kHz mono tracks, streamed
  TurnAssembler.swift          [TimedWord] -> [Turn]
  TranscriptRenderer.swift     [Turn] + metadata -> Markdown
  TranscriptionPipeline.swift  one WAV URL -> one .md, given a SpeechEngine
  TranscriptionQueue.swift     actor: FIFO of jobs, observable state
  ScribeError.swift            + modelsUnavailable, transcriptionFailed

Sources/ScribeTranscription   (depends on ScribeCore, FluidAudio)
  FluidAudioEngine.swift       SpeechEngine conformance

Sources/Scribe                (depends on both)
  AppState.swift               enqueue on save/interrupt, observe queue
  MenuView.swift               status line
  Notifier.swift               + transcriptSaved, transcriptionFailed

Sources/scribe-cli            (depends on both)
  transcribe <wav>             runs the pipeline with the real engine
```

`Package.swift` moves to `swift-tools-version: 6.2` (toolchain is 6.3.2) so
the FluidAudio dependency can be declared with `traits: []`.

### SpeechEngine

```swift
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: String
}

public struct SpeakerSegment: Equatable, Sendable {
    public var speakerID: String     // engine's opaque id, e.g. "S1"
    public var start: TimeInterval
    public var end: TimeInterval
}

public enum DiarizationOutcome: Equatable, Sendable {
    case segments([SpeakerSegment])
    case noSpeech
}

public protocol SpeechEngine: Sendable {
    /// Downloads and loads models if needed. Idempotent. Throws `.modelsUnavailable`.
    func prepare() async throws
    /// 16 kHz mono Float32 in, words with times in. `speaker` is left empty.
    func transcribe(_ track: [Float]) async throws -> [TimedWord]
    /// 16 kHz mono Float32 in. Never throws for "no speech".
    func diarize(_ track: [Float]) async throws -> DiarizationOutcome
}
```

`FluidAudioEngine` owns one `AsrManager` and one `OfflineDiarizerManager`.
`prepare()` calls `AsrModels.downloadAndLoad(version: .v2)` then
`loadModels`, and `prepareModels()` on the diarizer, wrapping any error in
`ScribeError.modelsUnavailable(description)`. `transcribe` makes a fresh
`TdtDecoderState` per call and maps `buildWordTimings` output to `TimedWord`.
`diarize` catches `OfflineDiarizationError.noSpeechDetected` and returns
`.noSpeech`; every other error becomes `ScribeError.transcriptionFailed`.

### ChannelReader

Opens the WAV with `ExtAudioFile`, sets the client format to Float32
interleaved stereo at 16 kHz so Core Audio resamples during the read, and
pulls blocks of 65,536 frames. Each block is deinterleaved into `left` and
`right`, clamped to -1...1, and appended. Result:

```swift
public struct ChannelTracks: Sendable {
    public var left: [Float]
    public var right: [Float]
    public var duration: TimeInterval    // frames / 16_000
}
public static func read(_ url: URL) throws -> ChannelTracks
```

Throws `ScribeError.transcriptionFailed` if the file cannot be opened, is not
two channels, or has zero frames. Peak memory is the two 16 kHz tracks (about
61 MB per channel-hour) plus one block.

### TranscriptionPipeline

```swift
public struct TranscriptionPipeline: Sendable {
    public init(engine: any SpeechEngine)
    /// Writes `<wav basename>.md` next to `wavURL` and returns its URL.
    public func run(_ wavURL: URL) async throws -> URL
}
```

Steps, in order:

1. `ChannelReader.read(wavURL)`.
2. `engine.transcribe(left)`; label every word "Me".
3. `engine.transcribe(right)`.
4. If step 3 produced any words, `engine.diarize(right)`; `.noSpeech` yields
   zero segments. If step 3 produced no words, skip diarization.
5. Assign each right word the speaker of the segment it overlaps most; if it
   overlaps none, the segment whose midpoint is nearest to the word's midpoint;
   if there are no segments at all (diarizer reported no speech), "Speaker 1",
   on the over-inclusive principle that words came from somebody. Speaker labels are
   "Speaker 1", "Speaker 2", ... numbered by the first start time of each
   engine speaker id across the segment list.
6. `TurnAssembler` over all words, `TranscriptRenderer` to a string, written
   with `Data.write(to:options: .atomic)` to the WAV's URL with
   `pathExtension` replaced by `md`. An existing file is replaced.

Steps 2 and 3 are sequential. Any thrown error propagates as-is if it is a
`ScribeError`, otherwise it is wrapped in `.transcriptionFailed`. Nothing is
written on failure.

### TurnAssembler

```swift
public struct Turn: Equatable, Sendable {
    public var speaker: String
    public var text: String     // words joined by single spaces
}

public struct TurnAssembler: Sendable {
    public init(phraseGap: TimeInterval = 0.7, turnGap: TimeInterval = 2.0)
    public func assemble(_ words: [TimedWord]) -> [Turn]
}
```

1. Group words by speaker. Within each speaker, sort by start and cut into
   phrases: a new phrase begins when `word.start - phrase.end > phraseGap`.
2. Sort all phrases by start time (stable; ties keep speaker grouping order).
3. Walk phrases: if the previous turn has the same speaker and
   `phrase.start - lastEnd <= turnGap`, append to it, where `lastEnd` is the
   latest end seen so far across all speakers; otherwise start a new turn.

Because phrases are formed inside one speaker's stream before any
interleaving, overlapping speech produces whole phrases from each speaker,
never word-by-word alternation.

### TranscriptRenderer

```swift
public struct TranscriptRenderer: Sendable {
    public func render(turns: [Turn], recordingName: String, duration: TimeInterval) -> String
}
```

Output:

```markdown
# Meeting 2026-09-16 14:30

Recording: 2026-09-16 14-30 Recording.wav
Duration: 47:12
Speakers: Me, Speaker 1, Speaker 2

**Me**
Hi both, thanks for joining. I wanted to go over the Q4 numbers.

**Speaker 1**
Sure. Before that, did you see the note from finance?
```

- Title: "Meeting " plus the `yyyy-MM-dd HH-mm` prefix of the recording name
  with the hour-minute separator changed to a colon. If the name does not
  start with that pattern, the title is "Meeting " plus the name without
  extension.
- Duration: `m:ss` under an hour, `h:mm:ss` at or above.
- Speakers: in order of first turn. With zero turns the line reads
  `Speakers: none` and no turn blocks follow.
- One blank line between header and first turn, between turns, and a
  trailing newline.

### TranscriptionQueue

```swift
public actor TranscriptionQueue {
    public enum State: Equatable, Sendable {
        case preparingModels
        case idle
        case transcribing(URL)
        case failed(URL, ScribeError)
    }
    public init(
        engine: any SpeechEngine,
        onStateChange: @escaping @Sendable (State) -> Void,
        onJobFinished: @escaping @Sendable (URL, Result<URL, ScribeError>) -> Void)
    public func prepareModels()        // kicks off engine.prepare() in the background
    public func enqueue(_ wavURL: URL) // FIFO
}
```

Behaviour:

- `prepareModels()` transitions to `.preparingModels`, awaits `engine.prepare()`,
  then `.idle`. On failure the state is also `.idle` and a private
  `modelsReady` flag stays false; no notification, since nothing was lost.
- `enqueue` appends and, if no job is running, starts the worker. The worker
  first ensures models are ready (calling `engine.prepare()` again if the
  launch attempt failed), then runs `TranscriptionPipeline.run` for the head
  URL, then the next, until the queue is empty.
- State is `.transcribing(url)` while a job runs, `.idle` after success,
  `.failed(url, error)` after a failure. A later success returns to `.idle`,
  which is what clears the menu line.
- A prepare failure during the worker reports `.failed(url, .modelsUnavailable)`
  for the head job and drops it, then continues with the next job the same
  way (which will fail identically unless the network came back). Simpler
  than a special-case abort and gives one notification per recording.
- App quit abandons the running job. Nothing is persisted.

### App integration

`AppState`:

- Creates `TranscriptionQueue(engine: FluidAudioEngine())` and calls
  `prepareModels()` in `init`, after `requestAuthorization()`.
- `recordingSaved(url)` and `recordingInterrupted(_, url:)` both call
  `queue.enqueue(url)` after their existing notification.
- Exposes `transcriptionStatus: String?` derived from queue state for the menu.
- Job completion goes to `Notifier`: `transcriptSaved(mdURL)` posts
  "Transcript saved" with the Markdown filename; `transcriptionFailed(wavURL,
  error)` posts "Transcription failed" with `error.userMessage`.

`MenuView` shows `transcriptionStatus` as a single `Text` line under the
recording controls, above the divider, whenever it is non-nil:

- `.preparingModels`: "Preparing transcription models…"
- `.transcribing(url)`: "Transcribing <filename without extension>…"
- `.failed(url, error)`: "<filename>: <error.userMessage>"
- `.idle`: nothing

`ScribeError` gains:

```swift
case modelsUnavailable(String)   // "Transcription models couldn't be loaded (<detail>)."
case transcriptionFailed(String) // "Transcription failed (<detail>)."
```

`scribe-cli transcribe <wav>` builds the same pipeline with `FluidAudioEngine`,
prints timing per stage to stderr, writes the `.md`, and prints its path.

## Error handling

| Situation | Result |
|---|---|
| Model download or load fails at launch | Silent; menu shows nothing; retried when the first job runs |
| Model download fails during a job | Job fails with `modelsUnavailable`; notification; menu line; WAV untouched |
| WAV unreadable or not stereo | `transcriptionFailed`; same treatment |
| Engine throws during ASR | `transcriptionFailed`; same treatment |
| Diarizer reports no speech but ASR found words | Not an error; every right word is "Speaker 1" |
| Left channel silent | Not an error; "Me" absent from speaker list |
| Both channels silent | Not an error; header with `Speakers: none` |
| Quit mid-job | Job abandoned; WAV untouched; no notification |
| A new recording starts mid-job | Unaffected; recording and transcription proceed together |

## Testing

All unit tests in `ScribeCoreTests`, run through `scripts/test.sh`, no
models, no audio hardware:

- `ChannelReaderTests`: WavWriter writes 2 s of 440 Hz sine on the left and
  silence on the right at 48 kHz; read back gives two tracks of 32,000
  samples, left RMS near the sine's, right all zero, every sample within
  -1...1. A mono AIFF written with `AVAudioFile` throws; a missing path throws.
- `TurnAssemblerTests`: (a) speaker A words at 0–3 s and speaker B words at
  1–2 s produce two turns, A then B, each a whole phrase; (b) a 0.8 s gap
  inside one speaker splits a phrase, 0.6 s does not; (c) two same-speaker
  phrases 1.5 s apart form one turn, 2.5 s apart form two; (d) empty input
  gives no turns; (e) the spike's interleaving pattern gives no single-word
  turns.
- `TranscriptRendererTests`: golden string for three turns; zero turns gives
  `Speakers: none`; durations 5 s, 62 s, 3723 s render as `0:05`, `1:02`,
  `1:02:03`; a name without the date prefix falls back to the bare name.
- `TranscriptionPipelineTests` with a fake engine: Markdown lands at the
  `.md` sibling; right words take the most-overlapping segment; a word with
  no overlap takes the nearest; speakers number by first appearance;
  `.noSpeech` with right words yields "Me" and "Speaker 1"; an empty left
  track yields no "Me"; an engine
  error yields `transcriptionFailed` and no file; an existing `.md` is
  replaced.
- `TranscriptionQueueTests` with a fake engine whose calls take a few
  milliseconds and count concurrent callers: two enqueued jobs run in order,
  one at a time; the observed
  state sequence is `preparingModels, idle, transcribing(a), idle,
  transcribing(b), idle`; a prepare failure at launch followed by success on
  enqueue transcribes normally; a job failure yields `failed` then a later
  success yields `idle`.

The FluidAudio adapter is covered manually. New section in
`docs/smoke-test.md`:

1. Fresh install (delete `~/Library/Application Support/FluidAudio`): launch,
   menu shows "Preparing transcription models…", then clears within a couple
   of minutes.
2. Record 30 s of speech on a call, stop: "Transcript saved" notification, an
   `.md` next to the WAV with "Me" and at least one numbered speaker.
3. `scribe-cli transcribe` on a real hour-long recording finishes in under two
   minutes; Activity Monitor peak memory under 1 GB.
4. Start a new recording while a long transcription runs; both proceed; the
   second recording's transcript arrives after the first.
5. Disconnect the network, delete the model cache, launch, record, stop:
   "Transcription failed" notification and menu line. Reconnect, record, stop:
   transcript arrives and the line clears.

## Out of scope

- Manual transcription of existing recordings (a menu item, later if wanted).
- Target folder for transcripts (phase 2.5).
- A retry queue that survives app restart.
- Per-turn timestamps, speaker naming, editing.
- Filtering background video or office noise out of the system channel.
- Summaries or any LLM step.
- Mic gain normalisation.
- Parakeet v3 or any non-English support.
