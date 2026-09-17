# Spike: does FluidAudio (Parakeet TDT v2 + offline VBx diarization) work on real Scribe recordings?

**Date:** 2026-09-16 · **Machine:** Apple M5 Pro, 24 GB, macOS 26.6.2, Swift 6.3.2 CLT · **Status:** answered, yes, with four design consequences

Throwaway investigation for the phase 2 transcription design. No repo code was changed. Scratch code lives in
`/private/tmp/claude-502/-Users-jacob-marchionda-Documents-scribe/655a75ec-7a93-4b2d-bba3-6b2d6a5eeaf3/scratchpad/`
(`transcribespike/`, a standalone SwiftPM package; `levels.swift`, a per-channel level meter). The generated
transcripts (`out-*.md`) and the word dump (`words-0915.tsv`) are in the same directory and contain real meeting
content, so they are not reproduced here.

## The question

Phase 1 pencilled in a Python sidecar (WhisperX + pyannote) for transcription. FluidAudio is a pure Swift,
CoreML-on-Neural-Engine alternative with an English-only Parakeet TDT v2 model and an offline pyannote
community-1 diarization pipeline (segmentation + WeSpeaker + VBx). Does it run on this machine, does it handle
Scribe's stereo WAVs (left = mic, right = system audio) at meeting length, and how fast is it?

## Method

One SwiftPM executable pinned to `FluidAudio` exact `0.15.7`:

1. Read the WAV with `AVAudioFile`, split into left and right `[Float]` at 48 kHz, resample each to 16 kHz mono
   with FluidAudio's `AudioConverter(sampleRate:).resample(_:from:)`.
2. `AsrModels.downloadAndLoad(version: .v2)`, `AsrManager(config: .default)`, `loadModels`, then
   `transcribe(_:decoderState:)` on each channel with a fresh `TdtDecoderState`. Words via the public
   `buildWordTimings(from:)`.
3. `OfflineDiarizerManager(config: .default)`, `prepareModels()`, `process(audio:)` on the right channel only.
4. Assign each right-channel word to the diarization segment it overlaps most (nearest segment if none), number
   speakers by first appearance, label every left-channel word "Me", merge into turns, write Markdown.

Run on four real recordings from `~/Music/Scribe/`, once cold (models downloaded) and again warm, under
`/usr/bin/time -l` for peak memory.

Note: the README's `transcribe(samples, source:)` overload does not exist at 0.15.7. The real batch entry point
takes `decoderState: inout TdtDecoderState` and is what the bundled CLI uses.

## Results

### Speed and memory (warm models)

| Recording | Audio | Load + split + resample | ASR left | ASR right | Diarization (right) | Total | Peak RSS |
|---|---|---|---|---|---|---|---|
| 09-16 22-42 | 39 s | 0.4 s | 0.25 s | 0.10 s | threw `noSpeechDetected` | n/a | n/a |
| 09-14 13-44 | 7.1 min | 4.2 s | 0.85 s | 1.4 s | 1.3 s | 8.1 s | 0.8 GB |
| 09-15 12-05 | 17.2 min | 10.1 s | 5.6 s | 3.6 s | 2.5 s | 22 s | 0.9 GB |
| 09-09 14-02 | 70.9 min | 42 s | 7.9 s | 11.3 s | 10.4 s | 72 s | **3.5 GB** |

- Whole pipeline runs at roughly 50 to 60x real time. ASR alone is 185 to 540x, diarization 340 to 410x.
- Reading and resampling the whole file up front is now the slowest stage (over half the total on the 70-minute
  file) and is what drives peak memory: 3.5 GB is the full-length Float32 stereo buffer plus both 16 kHz copies.
- Cold start on first run: ASR download plus CoreML compile 77 s, diarizer 12 s. Warm load is 0.2 s each.
- Model cache: `~/Library/Application Support/FluidAudio/Models/`, 451 MB for `parakeet-tdt-0.6b-v2`, 21 MB for
  `speaker-diarization`. 472 MB total.

### Transcript quality

- Right-channel (system audio) ASR is very good: punctuated, capitalised, confidence 0.92 to 0.97 on every file.
  Speaker turns read as coherent prose.
- Left-channel (mic) ASR is fine when the mic is actually loud: the 09-16 smoke recording gives confidence 0.94.
  On the 09-15 meeting the mic channel averages -40 dBFS with peaks over full scale and comes back at confidence
  0.70; some of that text reads as garbled. RMS normalisation before ASR made no difference (gain got capped by
  the clipped peaks; same word count and confidence). Parakeet's own mel normalisation handles gain; the
  limiting factor is the mic signal itself.
- No mic bleed: on the 09-15 file, 17 of 470 mic-channel words match a system-channel word within 2 s, against
  a chance level of 20 with the system channel shifted by 60 s. The AirPods/headphones assumption holds.
- Two of the four recordings have a mic channel that is digital silence (`-180 dBFS`, peak 0.00) for the whole
  file. Those are early phase 1 recordings, not a transcription issue, but the pipeline has to handle a channel
  with zero words.

### Diarization

- 7-minute meeting: 3 speakers on the system channel, 67 segments, all three with 85 to 117 s of speech.
- 17-minute meeting: 4 speakers, but two of them are tiny (2.1 s over 1 segment, 4.7 s over 2 segments).
- 70-minute meeting: 5 speakers, smallest 26 s over 15 segments.
- True speaker counts unknown at time of writing (question for the user). The pattern of one or two speakers with
  a few seconds of total speech looks like over-clustering, which FluidAudio's own AMI sweep also reports.
- Music-only or speech-free system audio makes `process(audio:)` throw `OfflineDiarizationError.noSpeechDetected`.

### Turn assembly: word-level interleaving is the real problem

The naive merge (sort every word from both channels by start time, break a turn on speaker change) produced 89
single-word "Me" turns on the 17-minute file, and split other speakers' sentences word by word around them. 39 % of
mic-channel words overlap system-channel speech in time, so any strictly time-ordered word merge will shred
sentences whenever two people talk at once.

Grouping words into phrases per speaker first (a pause over 0.7 s inside one speaker's stream ends a phrase),
then ordering phrases by start time, then merging adjacent same-speaker phrases into turns (gap up to 2 s) fixed it:

| File | Naive merge | Phrase-first merge |
|---|---|---|
| 09-15 12-05 | ~290 turns, 89+ single-word | 117 turns, 7 single-word |
| 09-14 13-44 | 19 turns, 3 single-word | 15 turns, 0 single-word |

### Other findings

- FluidAudio 0.15.7 pulls a 49 MB prebuilt Rust `NemoTextProcessing.xcframework` by default. It is only used by
  TTS and text normalisation. A `swift-tools-version: 6.2` manifest can opt out with
  `.package(url:..., exact:..., traits: [])`; the FluidAudio manifest documents this as the intended path for
  ASR-and-diarization-only apps. Our toolchain is 6.3.2, so bumping the tools version is available.
- Every run prints `E5RT encountered an STL exception ... ios17.slice_by_index: zero shape error` to stderr at
  exit. FluidAudio's docs identify it as a benign Neural Engine warning from the ASR preprocessor's flexible
  input shape. Harmless, but it will show up in Console.
- Both FluidAudio managers are Swift actors / classes that must be prepared once and can then be reused across
  jobs; per-job model reload is 0.2 s anyway.

## Recommendation

Adopt FluidAudio 0.15.7 (exact pin) for phase 2. Four consequences for the design:

1. **Stream the WAV in, per channel.** Read and resample in chunks rather than materialising the whole file;
   the goal is peak memory that does not scale with meeting length. ASR still wants each channel as one
   `[Float]` (about 61 MB per channel-hour at 16 kHz), which is fine; the 48 kHz stereo copy is what must go.
2. **Phrase-first turn assembly.** Per-speaker phrases by intra-speaker pause, then interleave, then merge.
   Pure logic, lives in ScribeCore, fully unit-testable with fake word timings.
3. **Degenerate inputs are normal.** A silent mic channel yields zero words and no "Me" in the speaker list.
   A speech-free system channel makes the diarizer throw `noSpeechDetected`; treat it as "no speakers on the
   system channel" and still transcribe the mic. Neither is a failure.
4. **Tiny speakers.** Decide a policy for diarization clusters with only a few seconds of total speech: merge
   into the nearest speaker, label as-is, or drop. Needs the user's ground truth on the 09-14 and 09-15 meetings
   before choosing.

Not adopted: mic-channel gain normalisation (no effect), the README's `source:` API (doesn't exist), and the
bundled text-normalisation binary (not needed; opt out via trait).
