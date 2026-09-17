# Phase 2 Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a recording stops, transcribe it on-device with FluidAudio and write a Markdown transcript next to the WAV, with the mic channel labelled "Me" and system-audio speakers labelled by diarization.

**Architecture:** All logic that can be tested without models lives in `ScribeCore`: a streaming stereo-WAV reader, a phrase-first turn assembler, a Markdown renderer, a pipeline that orchestrates them over a `SpeechEngine` protocol, and a serial job queue. A new `ScribeTranscription` target holds the one class that touches FluidAudio. The app enqueues every saved recording and shows queue state in the menu.

**Tech Stack:** Swift 6, SwiftPM (tools 6.2, no Xcode project), FluidAudio 0.15.7 (CoreML Parakeet TDT v2 + offline VBx diarization), AudioToolbox `ExtAudioFile`, Swift Testing, SwiftUI `MenuBarExtra`.

**Spec:** `docs/superpowers/specs/2026-09-17-scribe-phase2-transcription-design.md`. The spike it rests on is `docs/superpowers/spikes/2026-09-16-fluidaudio-transcription-spike.md`.

## Global Constraints

- **Minimum macOS 14.2.** Dev machine runs macOS 26.6.2, Swift 6.3.2 (Command Line Tools only, no Xcode.app).
- **Run tests with `scripts/test.sh`, never bare `swift test`.** The wrapper adds Testing.framework's search path and rpath. It forwards arguments: `scripts/test.sh --filter TurnAssemblerTests`.
- **Swift Testing, not XCTest.** Use `@Suite`, `@Test`, `#expect`, `#require`, `#expect(throws:)`.
- **FluidAudio is pinned `exact: "0.15.7"` with `traits: []`.** Never `from:`. The empty trait set keeps a 49 MB Rust binary that only TTS uses out of the link (SwiftPM still fetches it into `.build/artifacts/` at resolution; that is expected).
- **Only `Sources/ScribeTranscription` may `import FluidAudio`.** `ScribeCore` and `ScribeCoreTests` stay dependency-free so unit tests never download or load models.
- **The FluidAudio README is out of date.** At 0.15.7 the batch call is `AsrManager.transcribe(_:decoderState:)`; there is no `source:` overload. Words come from the public free function `buildWordTimings(from:)`. The diarizer throws `OfflineDiarizationError.noSpeechDetected` (no payload) on speech-free audio.
- **Model download needs the network and writes to `~/Library/Application Support/FluidAudio/Models/`** (472 MB). If a subagent runs under a sandbox, that run needs the sandbox disabled. Unit tests never need it.
- **Never touch the user's default audio devices.** Nothing in this plan should, but the rule from phase 1 stands.
- **Transcripts of real recordings contain private meeting content.** Never paste transcript text into commit messages, plan notes, or reports. Report counts and timings only.
- **Output format is fixed** by the spec: `<same basename>.md` next to the WAV, header lines `Recording:`, `Duration:`, `Speakers:`, then `**Speaker**` blocks, no timestamps.
- **Markdown filenames match the WAV**: `2026-09-16 14-30 Recording.wav` → `2026-09-16 14-30 Recording.md`.

---

## File Structure

**Create:**
- `Sources/ScribeCore/SpeechEngine.swift` — `SpeechEngine` protocol and the value types it exchanges: `TimedWord`, `SpeakerSegment`, `DiarizationOutcome`.
- `Sources/ScribeCore/TurnAssembler.swift` — `Turn` and `TurnAssembler`: words with speakers in, turns out. Phrase-first merge.
- `Sources/ScribeCore/TranscriptRenderer.swift` — `TranscriptRenderer`: turns plus metadata to Markdown.
- `Sources/ScribeCore/ChannelReader.swift` — `ChannelTracks` and `ChannelReader`: stereo WAV to two 16 kHz mono tracks, streamed through `ExtAudioFile`.
- `Sources/ScribeCore/TranscriptionPipeline.swift` — `TranscriptionPipeline`: one WAV URL to one `.md`, given any `SpeechEngine`.
- `Sources/ScribeCore/TranscriptionQueue.swift` — `TranscriptionQueue` actor: FIFO of jobs, one at a time, observable state.
- `Sources/ScribeTranscription/FluidAudioEngine.swift` — the only file that imports FluidAudio. `SpeechEngine` conformance.
- `Tests/ScribeCoreTests/TurnAssemblerTests.swift`, `TranscriptRendererTests.swift`, `ChannelReaderTests.swift`, `TranscriptionPipelineTests.swift`, `TranscriptionQueueTests.swift`.

**Modify:**
- `Package.swift` — tools 6.2, FluidAudio dependency, `ScribeTranscription` target, app and CLI depend on it.
- `Sources/ScribeCore/ScribeError.swift` — `modelsUnavailable(String)`, `transcriptionFailed(String)`.
- `Tests/ScribeCoreTests/ScribeErrorTests.swift` — the new cases.
- `Sources/scribe-cli/main.swift` — `transcribe <wav>` command.
- `Sources/Scribe/AppState.swift`, `MenuView.swift`, `Notifier.swift` — queue ownership, status line, two notifications.
- `docs/smoke-test.md`, `README.md` — manual checks and the new command.

Not modified: `scripts/bundle.sh`. FluidAudio ships a `FluidAudio_FluidAudio.bundle` resource bundle, but only its TTS code reads it, and the generated accessor falls back to the build directory on this machine. Leave it.

---

### Task 1: Package manifest and the new target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ScribeTranscription/FluidAudioEngine.swift` (placeholder; Task 8 fills it)
- Commit: `Package.resolved` (created by the first build)

**Interfaces:**
- Produces: a `ScribeTranscription` library target that `Scribe` and `scribe-cli` depend on, and the `FluidAudio` product available to it.

- [ ] **Step 1: Replace `Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "ScribeCore", targets: ["ScribeCore"]),
        .library(name: "ScribeTranscription", targets: ["ScribeTranscription"]),
        .executable(name: "Scribe", targets: ["Scribe"]),
        .executable(name: "scribe-cli", targets: ["scribe-cli"]),
    ],
    dependencies: [
        // Exact pin: FluidAudio moves fast. `traits: []` opts out of the
        // NemoTextProcessing binary, which only TTS uses.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.7", traits: []),
    ],
    targets: [
        .target(
            name: "ScribeCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .target(
            name: "ScribeTranscription",
            dependencies: [
                "ScribeCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(name: "Scribe", dependencies: ["ScribeCore", "ScribeTranscription"]),
        .executableTarget(name: "scribe-cli", dependencies: ["ScribeCore", "ScribeTranscription"]),
        .testTarget(name: "ScribeCoreTests", dependencies: ["ScribeCore"]),
    ]
)
```

- [ ] **Step 2: Create the placeholder source file**

`Sources/ScribeTranscription/FluidAudioEngine.swift`:

```swift
import FluidAudio
import ScribeCore

// FluidAudioEngine is implemented in Task 8. This file exists so the target
// compiles and the dependency resolves.
```

- [ ] **Step 3: Build everything**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`. The first build fetches FluidAudio and compiles it; allow 5 to 10 minutes. It needs the network. SwiftPM still downloads `NemoTextProcessing.xcframework.zip` into `.build/artifacts/` at resolution time regardless of traits (a SwiftPM behaviour, not a manifest error); what `traits: []` guarantees is that the binary is not compiled or linked. Verify that instead: `nm .build/debug/scribe-cli | grep -c text_processing_rs` must print `0`.

- [ ] **Step 4: Run the existing tests**

Run: `scripts/test.sh 2>&1 | tail -3`
Expected: all 52 existing tests pass. (The test build compiles FluidAudio too; that is expected.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved Sources/ScribeTranscription/FluidAudioEngine.swift
git commit -m "Add FluidAudio 0.15.7 and the ScribeTranscription target

Tools version moves to 6.2 so the dependency can be declared with an
empty trait set, which drops the text-normalisation binary that only
TTS needs.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: New error cases

**Files:**
- Modify: `Sources/ScribeCore/ScribeError.swift`
- Test: `Tests/ScribeCoreTests/ScribeErrorTests.swift`

**Interfaces:**
- Produces: `ScribeError.modelsUnavailable(String)` and `ScribeError.transcriptionFailed(String)`, each with a `userMessage`. Every later task throws these.

- [ ] **Step 1: Extend the test**

Replace the body of `ScribeErrorTests.swift` with:

```swift
import Testing
@testable import ScribeCore

@Suite struct ScribeErrorTests {
    @Test func everyCaseHasAUserMessage() {
        let cases: [ScribeError] = [
            .permissionDenied, .tapCreationFailed(-1), .aggregateCreationFailed(-2),
            .captureStartFailed(-3), .noInputDevice, .writeFailed(-4),
            .inputDeviceChanged, .notRecording, .alreadyRecording,
            .modelsUnavailable("offline"), .transcriptionFailed("boom"),
        ]
        for c in cases {
            #expect(!c.userMessage.isEmpty)
        }
        #expect(ScribeError.writeFailed(-4).userMessage.contains("-4"))
    }

    @Test func transcriptionMessagesCarryTheDetail() {
        #expect(ScribeError.modelsUnavailable("offline").userMessage == "Transcription models couldn't be loaded (offline).")
        #expect(ScribeError.transcriptionFailed("boom").userMessage == "Transcription failed (boom).")
    }
}
```

- [ ] **Step 2: Run the test to see it fail**

Run: `scripts/test.sh --filter ScribeErrorTests 2>&1 | grep -E "error:|passed|failed" | head`
Expected: compile error, `type 'ScribeError' has no member 'modelsUnavailable'`.

- [ ] **Step 3: Add the cases**

In `Sources/ScribeCore/ScribeError.swift`, after `case alreadyRecording`:

```swift
    /// Model download or load failed. The string is the underlying error's description.
    case modelsUnavailable(String)
    /// Anything else that stops a transcript from being written.
    case transcriptionFailed(String)
```

And in `userMessage`, after the `.alreadyRecording` case:

```swift
        case .modelsUnavailable(let detail):
            return "Transcription models couldn't be loaded (\(detail))."
        case .transcriptionFailed(let detail):
            return "Transcription failed (\(detail))."
```

- [ ] **Step 4: Run the test to see it pass**

Run: `scripts/test.sh --filter ScribeErrorTests 2>&1 | tail -3`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScribeCore/ScribeError.swift Tests/ScribeCoreTests/ScribeErrorTests.swift
git commit -m "Add transcription error cases

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Speech engine types and the turn assembler

**Files:**
- Create: `Sources/ScribeCore/SpeechEngine.swift`
- Create: `Sources/ScribeCore/TurnAssembler.swift`
- Test: `Tests/ScribeCoreTests/TurnAssemblerTests.swift`

**Interfaces:**
- Produces:
  - `struct TimedWord: Equatable, Sendable { var text: String; var start: TimeInterval; var end: TimeInterval; var speaker: String }` with a memberwise `public init`.
  - `struct SpeakerSegment: Equatable, Sendable { var speakerID: String; var start: TimeInterval; var end: TimeInterval }`.
  - `enum DiarizationOutcome: Equatable, Sendable { case segments([SpeakerSegment]); case noSpeech }`.
  - `protocol SpeechEngine: Sendable { func prepare() async throws; func transcribe(_ track: [Float]) async throws -> [TimedWord]; func diarize(_ track: [Float]) async throws -> DiarizationOutcome }`.
  - `struct Turn: Equatable, Sendable { var speaker: String; var text: String }`.
  - `struct TurnAssembler: Sendable { init(phraseGap: TimeInterval = 0.7, turnGap: TimeInterval = 2.0); func assemble(_ words: [TimedWord]) -> [Turn] }`.

- [ ] **Step 1: Write the engine types**

`Sources/ScribeCore/SpeechEngine.swift`:

```swift
import Foundation

/// One recognised word with its time span, and the speaker label the
/// pipeline assigns ("Me", "Speaker 1", ...). Engines leave `speaker` empty.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: String

    public init(text: String, start: TimeInterval, end: TimeInterval, speaker: String = "") {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// One span of speech attributed to an engine-defined speaker id (e.g. "S1").
public struct SpeakerSegment: Equatable, Sendable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

public enum DiarizationOutcome: Equatable, Sendable {
    case segments([SpeakerSegment])
    /// The diarizer found no speech at all. Not an error.
    case noSpeech
}

/// What the pipeline needs from a speech stack. Tracks are 16 kHz mono Float32.
public protocol SpeechEngine: Sendable {
    /// Downloads and loads models if needed. Idempotent. Throws `ScribeError.modelsUnavailable`.
    func prepare() async throws
    /// Recognised words with times. Throws `ScribeError.transcriptionFailed`.
    func transcribe(_ track: [Float]) async throws -> [TimedWord]
    /// Speaker segments. Returns `.noSpeech` rather than throwing when there is nothing to diarize.
    func diarize(_ track: [Float]) async throws -> DiarizationOutcome
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/ScribeCoreTests/TurnAssemblerTests.swift`:

```swift
import Foundation
import Testing
@testable import ScribeCore

@Suite struct TurnAssemblerTests {
    private func w(_ text: String, _ start: TimeInterval, _ end: TimeInterval, _ speaker: String) -> TimedWord {
        TimedWord(text: text, start: start, end: end, speaker: speaker)
    }

    @Test func overlappingSpeakersYieldWholePhrases() {
        // A talks 0-3 s; B interjects 1-2 s. Naive time-ordering would split A's sentence.
        let words = [
            w("one", 0.0, 0.5, "A"), w("two", 0.5, 1.0, "A"), w("three", 1.0, 1.5, "A"),
            w("four", 1.5, 2.0, "A"), w("five", 2.0, 2.5, "A"), w("six", 2.5, 3.0, "A"),
            w("yeah", 1.0, 1.4, "B"), w("right", 1.4, 2.0, "B"),
        ]
        let turns = TurnAssembler().assemble(words)
        #expect(turns == [
            Turn(speaker: "A", text: "one two three four five six"),
            Turn(speaker: "B", text: "yeah right"),
        ])
    }

    @Test func pauseLongerThanPhraseGapSplitsAPhrase() {
        let split = TurnAssembler(phraseGap: 0.7, turnGap: 0.1).assemble([
            w("a", 0.0, 0.5, "A"), w("b", 1.3, 1.8, "A"),   // gap 0.8 > 0.7
        ])
        #expect(split.count == 2)

        let joined = TurnAssembler(phraseGap: 0.7, turnGap: 0.1).assemble([
            w("a", 0.0, 0.5, "A"), w("b", 1.1, 1.6, "A"),   // gap 0.6 <= 0.7
        ])
        #expect(joined == [Turn(speaker: "A", text: "a b")])
    }

    @Test func sameSpeakerPhrasesMergeWithinTurnGap() {
        let one = TurnAssembler().assemble([
            w("a", 0.0, 0.5, "A"), w("b", 2.0, 2.5, "A"),   // phrase gap 1.5: two phrases, one turn
        ])
        #expect(one == [Turn(speaker: "A", text: "a b")])

        let two = TurnAssembler().assemble([
            w("a", 0.0, 0.5, "A"), w("b", 3.0, 3.5, "A"),   // 2.5 > 2.0: two turns
        ])
        #expect(two == [Turn(speaker: "A", text: "a"), Turn(speaker: "A", text: "b")])
    }

    @Test func otherSpeakerBetweenPhrasesBreaksTheTurn() {
        let turns = TurnAssembler().assemble([
            w("a", 0.0, 0.5, "A"), w("x", 1.0, 1.5, "B"), w("b", 2.0, 2.5, "A"),
        ])
        #expect(turns == [
            Turn(speaker: "A", text: "a"), Turn(speaker: "B", text: "x"), Turn(speaker: "A", text: "b"),
        ])
    }

    @Test func emptyInputYieldsNoTurns() {
        #expect(TurnAssembler().assemble([]).isEmpty)
    }

    @Test func spikeInterleavingPatternHasNoSingleWordTurns() {
        // "it's gonna be incredibly useful" with "yeah for sure" spoken over the middle of it.
        let them = ["it's", "gonna", "be", "incredibly", "useful"].enumerated().map { i, t in
            w(t, Double(i) * 0.4, Double(i) * 0.4 + 0.35, "Speaker 1")
        }
        let me = ["yeah", "for", "sure"].enumerated().map { i, t in
            w(t, 0.6 + Double(i) * 0.3, 0.6 + Double(i) * 0.3 + 0.25, "Me")
        }
        let turns = TurnAssembler().assemble(them + me)
        #expect(turns.count == 2)
        #expect(turns.allSatisfy { $0.text.split(separator: " ").count > 1 })
        #expect(turns[0].speaker == "Speaker 1")
        #expect(turns[1].speaker == "Me")
    }

    @Test func phrasesStartingAtTheSameTimeKeepFirstAppearanceOrder() {
        let turns = TurnAssembler().assemble([
            w("b", 0.0, 0.5, "B"), w("a", 0.0, 0.5, "A"),
        ])
        #expect(turns.map(\.speaker) == ["B", "A"])
    }
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `scripts/test.sh --filter TurnAssemblerTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'TurnAssembler' in scope`.

- [ ] **Step 4: Implement the assembler**

`Sources/ScribeCore/TurnAssembler.swift`:

```swift
import Foundation

/// One block in the transcript: a speaker and their words joined by spaces.
public struct Turn: Equatable, Sendable {
    public var speaker: String
    public var text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// Phrase-first merge. Words are grouped into phrases inside each speaker's
/// own stream (a pause over `phraseGap` ends a phrase), phrases are ordered by
/// start time, and adjacent same-speaker phrases within `turnGap` become one
/// turn. Because phrases form before any interleaving, two people talking at
/// once produce whole phrases rather than word-by-word alternation.
public struct TurnAssembler: Sendable {
    public let phraseGap: TimeInterval
    public let turnGap: TimeInterval

    public init(phraseGap: TimeInterval = 0.7, turnGap: TimeInterval = 2.0) {
        self.phraseGap = phraseGap
        self.turnGap = turnGap
    }

    private struct Phrase {
        var speaker: String
        var start: TimeInterval
        var end: TimeInterval
        var words: [String]
    }

    public func assemble(_ words: [TimedWord]) -> [Turn] {
        // Speakers in order of first appearance, so ties in start time are deterministic.
        var speakers: [String] = []
        for word in words where !speakers.contains(word.speaker) {
            speakers.append(word.speaker)
        }

        var phrases: [Phrase] = []
        for speaker in speakers {
            let stream = words.filter { $0.speaker == speaker }.sorted { $0.start < $1.start }
            var current: Phrase?
            for word in stream {
                if var phrase = current, word.start - phrase.end <= phraseGap {
                    phrase.words.append(word.text)
                    phrase.end = max(phrase.end, word.end)
                    current = phrase
                } else {
                    if let phrase = current { phrases.append(phrase) }
                    current = Phrase(speaker: speaker, start: word.start, end: word.end, words: [word.text])
                }
            }
            if let phrase = current { phrases.append(phrase) }
        }

        // Stable by construction: ties keep the order phrases were appended in.
        let ordered = phrases.enumerated()
            .sorted { a, b in
                a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start
            }
            .map(\.element)

        var turns: [Turn] = []
        var lastEnd = -TimeInterval.infinity
        for phrase in ordered {
            let text = phrase.words.joined(separator: " ")
            if let last = turns.last, last.speaker == phrase.speaker, phrase.start - lastEnd <= turnGap {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(speaker: phrase.speaker, text: text))
            }
            lastEnd = max(lastEnd, phrase.end)
        }
        return turns
    }
}
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `scripts/test.sh --filter TurnAssemblerTests 2>&1 | tail -3`
Expected: 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ScribeCore/SpeechEngine.swift Sources/ScribeCore/TurnAssembler.swift Tests/ScribeCoreTests/TurnAssemblerTests.swift
git commit -m "Add the SpeechEngine protocol and phrase-first turn assembler

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Markdown renderer

**Files:**
- Create: `Sources/ScribeCore/TranscriptRenderer.swift`
- Test: `Tests/ScribeCoreTests/TranscriptRendererTests.swift`

**Interfaces:**
- Consumes: `Turn` from Task 3.
- Produces: `struct TranscriptRenderer: Sendable { init(); func render(turns: [Turn], recordingName: String, duration: TimeInterval) -> String }`.

- [ ] **Step 1: Write the failing tests**

`Tests/ScribeCoreTests/TranscriptRendererTests.swift`:

```swift
import Foundation
import Testing
@testable import ScribeCore

@Suite struct TranscriptRendererTests {
    @Test func rendersHeaderAndTurns() {
        let turns = [
            Turn(speaker: "Me", text: "Hi both, thanks for joining."),
            Turn(speaker: "Speaker 1", text: "Sure. Did you see the note?"),
            Turn(speaker: "Me", text: "I did, yes."),
        ]
        let md = TranscriptRenderer().render(
            turns: turns, recordingName: "2026-09-16 14-30 Recording.wav", duration: 2832)
        #expect(md == """
            # Meeting 2026-09-16 14:30

            Recording: 2026-09-16 14-30 Recording.wav
            Duration: 47:12
            Speakers: Me, Speaker 1

            **Me**
            Hi both, thanks for joining.

            **Speaker 1**
            Sure. Did you see the note?

            **Me**
            I did, yes.

            """)
    }

    @Test func noTurnsRendersSpeakersNone() {
        let md = TranscriptRenderer().render(
            turns: [], recordingName: "2026-09-16 14-30 Recording.wav", duration: 5)
        #expect(md == """
            # Meeting 2026-09-16 14:30

            Recording: 2026-09-16 14-30 Recording.wav
            Duration: 0:05
            Speakers: none

            """)
    }

    @Test func speakersListedInOrderOfFirstTurn() {
        let turns = [
            Turn(speaker: "Speaker 2", text: "a"), Turn(speaker: "Me", text: "b"),
            Turn(speaker: "Speaker 2", text: "c"), Turn(speaker: "Speaker 1", text: "d"),
        ]
        let md = TranscriptRenderer().render(turns: turns, recordingName: "x.wav", duration: 0)
        #expect(md.contains("Speakers: Speaker 2, Me, Speaker 1\n"))
    }

    @Test func durationFormatting() {
        #expect(TranscriptRenderer.formatDuration(5) == "0:05")
        #expect(TranscriptRenderer.formatDuration(62) == "1:02")
        #expect(TranscriptRenderer.formatDuration(3723) == "1:02:03")
        #expect(TranscriptRenderer.formatDuration(3599.9) == "59:59")
    }

    @Test func titleFallsBackToBareNameWithoutDatePrefix() {
        #expect(TranscriptRenderer.title(for: "2026-09-16 14-30 Recording (2).wav") == "Meeting 2026-09-16 14:30")
        #expect(TranscriptRenderer.title(for: "standup.wav") == "Meeting standup")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `scripts/test.sh --filter TranscriptRendererTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'TranscriptRenderer' in scope`.

- [ ] **Step 3: Implement the renderer**

`Sources/ScribeCore/TranscriptRenderer.swift`:

```swift
import Foundation

/// Renders turns to the phase 2 Markdown layout. No timestamps by design.
public struct TranscriptRenderer: Sendable {
    public init() {}

    public func render(turns: [Turn], recordingName: String, duration: TimeInterval) -> String {
        var speakers: [String] = []
        for turn in turns where !speakers.contains(turn.speaker) {
            speakers.append(turn.speaker)
        }

        var out = "# \(Self.title(for: recordingName))\n\n"
        out += "Recording: \(recordingName)\n"
        out += "Duration: \(Self.formatDuration(duration))\n"
        out += "Speakers: \(speakers.isEmpty ? "none" : speakers.joined(separator: ", "))\n"
        for turn in turns {
            out += "\n**\(turn.speaker)**\n\(turn.text)\n"
        }
        return out
    }

    /// "Meeting 2026-09-16 14:30" from a `yyyy-MM-dd HH-mm ...` name;
    /// otherwise "Meeting <name without extension>".
    static func title(for recordingName: String) -> String {
        let base = (recordingName as NSString).deletingPathExtension
        if let m = base.prefixMatch(of: /(\d{4}-\d{2}-\d{2}) (\d{2})-(\d{2})/) {
            return "Meeting \(m.1) \(m.2):\(m.3)"
        }
        return "Meeting \(base)"
    }

    /// `m:ss` under an hour, `h:mm:ss` from an hour up.
    static func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `scripts/test.sh --filter TranscriptRendererTests 2>&1 | tail -3`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScribeCore/TranscriptRenderer.swift Tests/ScribeCoreTests/TranscriptRendererTests.swift
git commit -m "Add the Markdown transcript renderer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Streaming channel reader

**Files:**
- Create: `Sources/ScribeCore/ChannelReader.swift`
- Test: `Tests/ScribeCoreTests/ChannelReaderTests.swift`

**Interfaces:**
- Consumes: `WavWriter` and `StereoBuffer` (existing) in the test only.
- Produces: `struct ChannelTracks: Sendable { var left: [Float]; var right: [Float]; var duration: TimeInterval }` and `enum ChannelReader { static let sampleRate: Double = 16_000; static func read(_ url: URL) throws -> ChannelTracks }`.

- [ ] **Step 1: Write the failing tests**

`Tests/ScribeCoreTests/ChannelReaderTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import ScribeCore

@Suite struct ChannelReaderTests {
    private func tempURL(_ ext: String = "wav") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(UUID().uuidString).\(ext)")
    }

    /// 48 kHz stereo WAV via WavWriter: 440 Hz sine at 0.5 on the left, silence on the right.
    private func writeSineWav(seconds: Double) throws -> URL {
        let url = tempURL()
        let writer = try WavWriter(url: url, inputSampleRate: 48_000)
        let chunk = 4800
        let buffer = StereoBuffer(capacityFrames: chunk)
        let total = Int(seconds * 48_000)
        var written = 0
        while written < total {
            let n = min(chunk, total - written)
            for f in 0..<n {
                let t = Double(written + f) / 48_000
                buffer.samples[2 * f] = Float(0.5 * sin(2 * .pi * 440 * t))
                buffer.samples[2 * f + 1] = 0
            }
            try writer.write(frames: UInt32(n), buffer.bufferList(frames: n))
            written += n
        }
        try writer.close()
        return url
    }

    @Test func splitsAndResamplesTo16k() throws {
        let url = try writeSineWav(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let tracks = try ChannelReader.read(url)

        #expect(abs(tracks.left.count - 32_000) <= 64)
        #expect(tracks.right.count == tracks.left.count)
        #expect(abs(tracks.duration - 2.0) < 0.01)

        let rms = sqrt(tracks.left.reduce(0) { $0 + Double($1 * $1) } / Double(tracks.left.count))
        #expect(abs(rms - 0.3536) < 0.02)              // 0.5 / sqrt(2)
        #expect(tracks.right.allSatisfy { abs($0) < 1e-4 })
        #expect(tracks.left.allSatisfy { $0 >= -1 && $0 <= 1 })
    }

    @Test func monoFileThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        try file.write(from: buffer)

        #expect(throws: ScribeError.self) { try ChannelReader.read(url) }
    }

    @Test func missingFileThrows() {
        #expect(throws: ScribeError.self) { try ChannelReader.read(tempURL()) }
    }

    @Test func emptyFileThrows() throws {
        let url = try writeSineWav(seconds: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ScribeError.self) { try ChannelReader.read(url) }
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `scripts/test.sh --filter ChannelReaderTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'ChannelReader' in scope`.

- [ ] **Step 3: Implement the reader**

`Sources/ScribeCore/ChannelReader.swift`:

```swift
import AudioToolbox
import Foundation

/// A Scribe recording split into its two channels at the speech models' rate.
public struct ChannelTracks: Sendable {
    /// Mic channel, 16 kHz mono.
    public var left: [Float]
    /// System-audio channel, 16 kHz mono.
    public var right: [Float]
    public var duration: TimeInterval

    public init(left: [Float], right: [Float], duration: TimeInterval) {
        self.left = left
        self.right = right
        self.duration = duration
    }
}

/// Streams a stereo WAV through `ExtAudioFile` with a 16 kHz Float32 client
/// format, so Core Audio resamples on the way in and the 48 kHz file is never
/// held in memory. Peak memory is the two 16 kHz tracks plus one block.
public enum ChannelReader {
    public static let sampleRate: Double = 16_000
    static let blockFrames = 65_536

    public static func read(_ url: URL) throws -> ChannelTracks {
        var ref: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(url as CFURL, &ref)
        guard status == noErr, let file = ref else {
            throw ScribeError.transcriptionFailed("couldn't open \(url.lastPathComponent) (error \(status))")
        }
        defer { ExtAudioFileDispose(file) }

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)
        guard status == noErr else {
            throw ScribeError.transcriptionFailed("couldn't read the format of \(url.lastPathComponent) (error \(status))")
        }
        guard fileFormat.mChannelsPerFrame == 2 else {
            throw ScribeError.transcriptionFailed(
                "expected a stereo recording, got \(fileFormat.mChannelsPerFrame) channel(s)")
        }

        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else {
            throw ScribeError.transcriptionFailed("couldn't set up resampling (error \(status))")
        }

        var left: [Float] = []
        var right: [Float] = []
        var scratch = [Float](repeating: 0, count: blockFrames * 2)
        while true {
            var frames = UInt32(blockFrames)
            let readStatus = scratch.withUnsafeMutableBufferPointer { buf -> OSStatus in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(buf.count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(buf.baseAddress)))
                return ExtAudioFileRead(file, &frames, &list)
            }
            guard readStatus == noErr else {
                throw ScribeError.transcriptionFailed("couldn't read \(url.lastPathComponent) (error \(readStatus))")
            }
            if frames == 0 { break }
            let n = Int(frames)
            left.reserveCapacity(left.count + n)
            right.reserveCapacity(right.count + n)
            for f in 0..<n {
                left.append(min(max(scratch[2 * f], -1), 1))
                right.append(min(max(scratch[2 * f + 1], -1), 1))
            }
        }

        guard !left.isEmpty else {
            throw ScribeError.transcriptionFailed("\(url.lastPathComponent) contains no audio")
        }
        return ChannelTracks(left: left, right: right, duration: Double(left.count) / sampleRate)
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `scripts/test.sh --filter ChannelReaderTests 2>&1 | tail -3`
Expected: 4 tests pass. If `splitsAndResamplesTo16k` fails on the count tolerance, print `tracks.left.count` and widen the tolerance to 160 (10 ms); the resampler's priming delay differs by OS version. Do not widen further without understanding why.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScribeCore/ChannelReader.swift Tests/ScribeCoreTests/ChannelReaderTests.swift
git commit -m "Add the streaming stereo WAV to 16 kHz channel reader

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Transcription pipeline

**Files:**
- Create: `Sources/ScribeCore/TranscriptionPipeline.swift`
- Test: `Tests/ScribeCoreTests/TranscriptionPipelineTests.swift`

**Interfaces:**
- Consumes: `SpeechEngine`, `TimedWord`, `SpeakerSegment`, `DiarizationOutcome` (Task 3), `TurnAssembler` (Task 3), `TranscriptRenderer` (Task 4), `ChannelReader`/`ChannelTracks` (Task 5), `ScribeError` (Task 2).
- Produces:
  - `struct TranscriptionPipeline: Sendable { typealias Reader = @Sendable (URL) throws -> ChannelTracks; init(engine: any SpeechEngine, read: @escaping Reader = ChannelReader.read); func run(_ wavURL: URL) async throws -> URL; static func transcriptURL(for wavURL: URL) -> URL }`.
  - The `.md` lands at `transcriptURL(for:)`, i.e. the WAV path with its extension replaced by `md`.

- [ ] **Step 1: Write the failing tests**

`Tests/ScribeCoreTests/TranscriptionPipelineTests.swift`:

```swift
import Foundation
import Testing
@testable import ScribeCore

/// Returns canned words per transcribe call, in call order (left first, then right).
actor FakeEngine: SpeechEngine {
    var transcribeResults: [[TimedWord]]
    var diarizeResult: DiarizationOutcome
    var transcribeError: ScribeError?
    private(set) var transcribeCalls = 0
    private(set) var diarizeCalls = 0

    init(left: [TimedWord] = [], right: [TimedWord] = [], diarize: DiarizationOutcome = .noSpeech) {
        transcribeResults = [left, right]
        diarizeResult = diarize
    }

    func setTranscribeError(_ error: ScribeError?) { transcribeError = error }

    func prepare() async throws {}

    func transcribe(_ track: [Float]) async throws -> [TimedWord] {
        transcribeCalls += 1
        if let transcribeError { throw transcribeError }
        return transcribeResults.isEmpty ? [] : transcribeResults.removeFirst()
    }

    func diarize(_ track: [Float]) async throws -> DiarizationOutcome {
        diarizeCalls += 1
        return diarizeResult
    }
}

@Suite struct TranscriptionPipelineTests {
    private func w(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedWord {
        TimedWord(text: text, start: start, end: end)
    }
    private func seg(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> SpeakerSegment {
        SpeakerSegment(speakerID: id, start: start, end: end)
    }

    /// A temp directory plus a WAV URL in it. The WAV need not exist: the reader is stubbed.
    private func scratch() throws -> (dir: URL, wav: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("2026-09-16 14-30 Recording.wav"))
    }

    private let stubReader: TranscriptionPipeline.Reader = { _ in
        ChannelTracks(left: [0], right: [0], duration: 65)
    }

    @Test func writesMarkdownNextToTheWav() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine(
            left: [w("hi", 0.0, 0.5)],
            right: [w("hello", 1.0, 1.5)],
            diarize: .segments([seg("S1", 0.9, 1.6)]))

        let out = try await TranscriptionPipeline(engine: engine, read: stubReader).run(wav)

        #expect(out == dir.appendingPathComponent("2026-09-16 14-30 Recording.md"))
        let md = try String(contentsOf: out, encoding: .utf8)
        #expect(md.hasPrefix("# Meeting 2026-09-16 14:30\n"))
        #expect(md.contains("Duration: 1:05\n"))
        #expect(md.contains("Speakers: Me, Speaker 1\n"))
        #expect(md.contains("**Me**\nhi\n"))
        #expect(md.contains("**Speaker 1**\nhello\n"))
    }

    @Test func mostOverlappingSegmentWins() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine(
            right: [w("word", 1.0, 2.0)],
            diarize: .segments([seg("A", 0.0, 1.2), seg("B", 1.2, 3.0)]))

        let md = try String(contentsOf: try await TranscriptionPipeline(engine: engine, read: stubReader).run(wav), encoding: .utf8)
        #expect(md.contains("**Speaker 2**\nword\n"))
    }

    @Test func nearestSegmentWhenNothingOverlaps() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine(
            right: [w("word", 5.0, 5.5)],
            diarize: .segments([seg("A", 0.0, 1.0), seg("B", 8.0, 9.0)]))

        let md = try String(contentsOf: try await TranscriptionPipeline(engine: engine, read: stubReader).run(wav), encoding: .utf8)
        #expect(md.contains("**Speaker 2**\nword\n"))
    }

    @Test func speakersNumberedByFirstAppearanceInTime() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine(
            right: [w("early", 0.2, 0.8), w("late", 2.2, 2.8)],
            diarize: .segments([seg("S2", 2.0, 3.0), seg("S9", 0.0, 1.0)]))   // out of order on purpose

        let md = try String(contentsOf: try await TranscriptionPipeline(engine: engine, read: stubReader).run(wav), encoding: .utf8)
        #expect(md.contains("**Speaker 1**\nearly\n"))
        #expect(md.contains("**Speaker 2**\nlate\n"))
    }

    @Test func noSpeechFromDiarizerLabelsRightWordsSpeakerOne() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine(left: [w("hi", 0, 0.5)], right: [w("hello", 1, 1.5)], diarize: .noSpeech)

        let md = try String(contentsOf: try await TranscriptionPipeline(engine: engine, read: stubReader).run(wav), encoding: .utf8)
        #expect(md.contains("Speakers: Me, Speaker 1\n"))
        #expect(await engine.diarizeCalls == 1)
    }

    @Test func silentLeftChannelHasNoMe() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine(right: [w("hello", 1, 1.5)], diarize: .segments([seg("S1", 0, 2)]))

        let md = try String(contentsOf: try await TranscriptionPipeline(engine: engine, read: stubReader).run(wav), encoding: .utf8)
        #expect(md.contains("Speakers: Speaker 1\n"))
        #expect(!md.contains("**Me**"))
    }

    @Test func silentRightChannelSkipsDiarization() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine(left: [w("hi", 0, 0.5)])

        let md = try String(contentsOf: try await TranscriptionPipeline(engine: engine, read: stubReader).run(wav), encoding: .utf8)
        #expect(md.contains("Speakers: Me\n"))
        #expect(await engine.diarizeCalls == 0)
    }

    @Test func bothChannelsSilentStillWritesAFile() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let md = try String(contentsOf: try await TranscriptionPipeline(engine: FakeEngine(), read: stubReader).run(wav), encoding: .utf8)
        #expect(md.hasSuffix("Speakers: none\n"))
    }

    @Test func engineErrorPropagatesAndWritesNothing() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = FakeEngine()
        await engine.setTranscribeError(.transcriptionFailed("boom"))
        let pipeline = TranscriptionPipeline(engine: engine, read: stubReader)

        await #expect(throws: ScribeError.transcriptionFailed("boom")) { try await pipeline.run(wav) }
        #expect(!FileManager.default.fileExists(atPath: TranscriptionPipeline.transcriptURL(for: wav).path))
    }

    @Test func readerErrorBecomesTranscriptionFailed() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Boom: Error {}
        let pipeline = TranscriptionPipeline(engine: FakeEngine(), read: { _ in throw Boom() })

        await #expect(throws: ScribeError.self) { try await pipeline.run(wav) }
        #expect(!FileManager.default.fileExists(atPath: TranscriptionPipeline.transcriptURL(for: wav).path))
    }

    @Test func replacesAnExistingTranscript() async throws {
        let (dir, wav) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = TranscriptionPipeline.transcriptURL(for: wav)
        try "old".write(to: out, atomically: true, encoding: .utf8)

        _ = try await TranscriptionPipeline(engine: FakeEngine(), read: stubReader).run(wav)
        #expect(try String(contentsOf: out, encoding: .utf8) != "old")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `scripts/test.sh --filter TranscriptionPipelineTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'TranscriptionPipeline' in scope`.

- [ ] **Step 3: Implement the pipeline**

`Sources/ScribeCore/TranscriptionPipeline.swift`:

```swift
import Foundation

/// One WAV in, one Markdown transcript out, next to it. Pure orchestration:
/// the engine, the reader, the assembler and the renderer are all injectable.
public struct TranscriptionPipeline: Sendable {
    public typealias Reader = @Sendable (URL) throws -> ChannelTracks

    private let engine: any SpeechEngine
    private let read: Reader
    private let assembler: TurnAssembler
    private let renderer: TranscriptRenderer

    public init(
        engine: any SpeechEngine,
        read: @escaping Reader = ChannelReader.read,
        assembler: TurnAssembler = TurnAssembler(),
        renderer: TranscriptRenderer = TranscriptRenderer()
    ) {
        self.engine = engine
        self.read = read
        self.assembler = assembler
        self.renderer = renderer
    }

    /// `<wav basename>.md` in the WAV's directory.
    public static func transcriptURL(for wavURL: URL) -> URL {
        wavURL.deletingPathExtension().appendingPathExtension("md")
    }

    /// Writes the transcript and returns its URL. Throws `ScribeError` only;
    /// nothing is written on failure.
    public func run(_ wavURL: URL) async throws -> URL {
        do {
            let tracks = try read(wavURL)

            let me = try await engine.transcribe(tracks.left).map { word in
                var w = word
                w.speaker = "Me"
                return w
            }

            var them = try await engine.transcribe(tracks.right)
            if !them.isEmpty {
                let segments: [SpeakerSegment]
                switch try await engine.diarize(tracks.right) {
                case .segments(let s): segments = s
                case .noSpeech: segments = []
                }
                them = Self.label(them, with: segments)
            }

            let turns = assembler.assemble(me + them)
            let markdown = renderer.render(
                turns: turns, recordingName: wavURL.lastPathComponent, duration: tracks.duration)
            let outURL = Self.transcriptURL(for: wavURL)
            try Data(markdown.utf8).write(to: outURL, options: .atomic)
            return outURL
        } catch let error as ScribeError {
            throw error
        } catch {
            throw ScribeError.transcriptionFailed(String(describing: error))
        }
    }

    /// Gives every right-channel word a "Speaker N" label. N is by first
    /// appearance of the engine's speaker id in time. A word takes the segment
    /// it overlaps most, else the segment whose midpoint is nearest. With no
    /// segments at all every word is "Speaker 1": the words came from somebody.
    static func label(_ words: [TimedWord], with segments: [SpeakerSegment]) -> [TimedWord] {
        guard !segments.isEmpty else {
            return words.map { word in
                var w = word
                w.speaker = "Speaker 1"
                return w
            }
        }

        let ordered = segments.sorted { $0.start < $1.start }
        var names: [String: String] = [:]
        for segment in ordered where names[segment.speakerID] == nil {
            names[segment.speakerID] = "Speaker \(names.count + 1)"
        }

        return words.map { word in
            var best: (id: String, overlap: TimeInterval)?
            for segment in ordered {
                let overlap = min(word.end, segment.end) - max(word.start, segment.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (segment.speakerID, overlap)
                }
            }
            let id: String
            if let best {
                id = best.id
            } else {
                let mid = (word.start + word.end) / 2
                id = ordered.min {
                    abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid)
                }!.speakerID
            }
            var w = word
            w.speaker = names[id]!
            return w
        }
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `scripts/test.sh --filter TranscriptionPipelineTests 2>&1 | tail -3`
Expected: 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ScribeCore/TranscriptionPipeline.swift Tests/ScribeCoreTests/TranscriptionPipelineTests.swift
git commit -m "Add the transcription pipeline with speaker labelling

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Serial transcription queue

**Files:**
- Create: `Sources/ScribeCore/TranscriptionQueue.swift`
- Test: `Tests/ScribeCoreTests/TranscriptionQueueTests.swift`

**Interfaces:**
- Consumes: `SpeechEngine` (Task 3), `TranscriptionPipeline` (Task 6), `ScribeError` (Task 2).
- Produces:
  ```swift
  public actor TranscriptionQueue {
      public enum State: Equatable, Sendable { case preparingModels, idle, transcribing(URL), failed(URL, ScribeError) }
      public typealias StateHandler = @Sendable (State) -> Void
      public typealias JobHandler = @Sendable (URL, Result<URL, ScribeError>) -> Void
      public init(engine: any SpeechEngine, pipeline: TranscriptionPipeline? = nil,
                  onStateChange: @escaping StateHandler, onJobFinished: @escaping JobHandler)
      public func prepareModels()
      public func enqueue(_ wavURL: URL)
      public var state: State { get }
  }
  ```
  `onStateChange` fires on every distinct state change, from the actor's context. `onJobFinished` fires once per enqueued URL.

- [ ] **Step 1: Write the failing tests**

`Tests/ScribeCoreTests/TranscriptionQueueTests.swift`:

```swift
import Foundation
import Testing
@testable import ScribeCore

/// Thread-safe append-only log for callbacks that arrive off the test's task.
final class Log<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

/// Slow enough to observe overlap, counts concurrent callers, can fail on demand.
actor SlowEngine: SpeechEngine {
    var prepareFailuresRemaining = 0
    var transcribeFailuresRemaining = 0
    private(set) var prepareCalls = 0
    private(set) var active = 0
    private(set) var maxActive = 0

    func setPrepareFailures(_ n: Int) { prepareFailuresRemaining = n }
    func setTranscribeFailures(_ n: Int) { transcribeFailuresRemaining = n }

    func prepare() async throws {
        prepareCalls += 1
        if prepareFailuresRemaining > 0 {
            prepareFailuresRemaining -= 1
            throw ScribeError.modelsUnavailable("offline")
        }
    }

    func transcribe(_ track: [Float]) async throws -> [TimedWord] {
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        try? await Task.sleep(for: .milliseconds(20))
        if transcribeFailuresRemaining > 0 {
            transcribeFailuresRemaining -= 1
            throw ScribeError.transcriptionFailed("boom")
        }
        return [TimedWord(text: "hi", start: 0, end: 0.5)]
    }

    func diarize(_ track: [Float]) async throws -> DiarizationOutcome { .noSpeech }
}

/// Polls `condition` every 10 ms for up to `timeout` seconds.
func eventually(_ timeout: TimeInterval = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite struct TranscriptionQueueTests {
    private struct Harness {
        let dir: URL
        let engine: SlowEngine
        let states = Log<TranscriptionQueue.State>()
        let finished = Log<(URL, Result<URL, ScribeError>)>()
        let queue: TranscriptionQueue

        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            engine = SlowEngine()
            let pipeline = TranscriptionPipeline(engine: engine, read: { _ in
                ChannelTracks(left: [0], right: [0], duration: 1)
            })
            let states = self.states, finished = self.finished
            queue = TranscriptionQueue(
                engine: engine, pipeline: pipeline,
                onStateChange: { states.append($0) },
                onJobFinished: { finished.append(($0, $1)) })
        }

        func wav(_ name: String) -> URL { dir.appendingPathComponent("\(name).wav") }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func jobsRunInOrderOneAtATime() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let a = h.wav("a"), b = h.wav("b")

        await h.queue.enqueue(a)
        await h.queue.enqueue(b)

        #expect(await eventually { h.finished.all.count == 2 })
        #expect(h.finished.all.map(\.0) == [a, b])
        #expect(await h.engine.maxActive == 1)
        #expect(h.states.all == [.transcribing(a), .idle, .transcribing(b), .idle])
        #expect(FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("a.md").path))
        #expect(FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("b.md").path))
    }

    @Test func prepareAtLaunchThenIdleAndNotRepeated() async throws {
        let h = try Harness()
        defer { h.cleanup() }

        await h.queue.prepareModels()
        #expect(await eventually { h.states.all == [.preparingModels, .idle] })

        await h.queue.enqueue(h.wav("a"))
        #expect(await eventually { h.finished.all.count == 1 })
        #expect(await h.engine.prepareCalls == 1)
    }

    @Test func prepareFailureAtLaunchRetriesOnEnqueue() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.engine.setPrepareFailures(1)

        await h.queue.prepareModels()
        #expect(await eventually { h.states.all == [.preparingModels, .idle] })

        let a = h.wav("a")
        await h.queue.enqueue(a)
        #expect(await eventually { h.finished.all.count == 1 })
        #expect(await h.engine.prepareCalls == 2)
        if case .success = h.finished.all[0].1 {} else { Issue.record("expected success after retry") }
    }

    @Test func jobFailureThenLaterSuccessReturnsToIdle() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.engine.setTranscribeFailures(1)
        let a = h.wav("a"), b = h.wav("b")

        await h.queue.enqueue(a)
        await h.queue.enqueue(b)

        #expect(await eventually { h.finished.all.count == 2 })
        #expect(h.states.all == [
            .transcribing(a), .failed(a, .transcriptionFailed("boom")), .transcribing(b), .idle,
        ])
        if case .failure(let e) = h.finished.all[0].1 { #expect(e == .transcriptionFailed("boom")) } else { Issue.record("expected failure") }
        if case .success = h.finished.all[1].1 {} else { Issue.record("expected success") }
        #expect(!FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("a.md").path))
    }

    @Test func modelsUnavailableFailsTheJob() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.engine.setPrepareFailures(10)
        let a = h.wav("a")

        await h.queue.enqueue(a)

        #expect(await eventually { h.finished.all.count == 1 })
        if case .failed(let url, .modelsUnavailable) = h.states.all.last { #expect(url == a) } else { Issue.record("expected failed(modelsUnavailable), got \(h.states.all)") }
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `scripts/test.sh --filter TranscriptionQueueTests 2>&1 | grep -E "error:" | head -3`
Expected: `cannot find 'TranscriptionQueue' in scope`.

- [ ] **Step 3: Implement the queue**

`Sources/ScribeCore/TranscriptionQueue.swift`:

```swift
import Foundation

/// Runs transcription jobs one at a time in arrival order and reports state.
/// Owns nothing persistent: quitting the app abandons whatever is queued.
public actor TranscriptionQueue {
    public enum State: Equatable, Sendable {
        case preparingModels
        case idle
        case transcribing(URL)
        case failed(URL, ScribeError)
    }

    public typealias StateHandler = @Sendable (State) -> Void
    public typealias JobHandler = @Sendable (URL, Result<URL, ScribeError>) -> Void

    private let engine: any SpeechEngine
    private let pipeline: TranscriptionPipeline
    private let onStateChange: StateHandler
    private let onJobFinished: JobHandler

    private var pending: [URL] = []
    private var draining = false
    private var modelsReady = false
    private var launchPrepare: Task<Void, Never>?

    public private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange(state) } }
    }

    public init(
        engine: any SpeechEngine,
        pipeline: TranscriptionPipeline? = nil,
        onStateChange: @escaping StateHandler,
        onJobFinished: @escaping JobHandler
    ) {
        self.engine = engine
        self.pipeline = pipeline ?? TranscriptionPipeline(engine: engine)
        self.onStateChange = onStateChange
        self.onJobFinished = onJobFinished
    }

    /// Starts the launch-time model download in the background. Failure is
    /// silent here; the next job retries and reports.
    public func prepareModels() {
        guard !modelsReady, launchPrepare == nil else { return }
        state = .preparingModels
        launchPrepare = Task { await self.runLaunchPrepare() }
    }

    private func runLaunchPrepare() async {
        do {
            try await engine.prepare()
            modelsReady = true
        } catch {
            modelsReady = false
        }
        launchPrepare = nil
        if case .preparingModels = state { state = .idle }
    }

    public func enqueue(_ wavURL: URL) {
        pending.append(wavURL)
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let url = pending.removeFirst()
            state = .transcribing(url)
            do {
                try await ensureModelsReady()
                let out = try await pipeline.run(url)
                state = .idle
                onJobFinished(url, .success(out))
            } catch {
                let failure = (error as? ScribeError) ?? .transcriptionFailed(String(describing: error))
                state = .failed(url, failure)
                onJobFinished(url, .failure(failure))
            }
        }
        draining = false
    }

    /// Waits for an in-flight launch prepare, then retries inline if needed.
    private func ensureModelsReady() async throws {
        if modelsReady { return }
        if let launchPrepare { await launchPrepare.value }
        if modelsReady { return }
        try await engine.prepare()
        modelsReady = true
    }
}
```

- [ ] **Step 4: Run the tests to see them pass**

Run: `scripts/test.sh --filter TranscriptionQueueTests 2>&1 | tail -3`
Expected: 5 tests pass. Run it three times to check for flakiness; the sleeps are generous but if a state-sequence assertion flakes, raise the engine's sleep to 50 ms rather than loosening the assertion.

- [ ] **Step 5: Run the whole suite**

Run: `scripts/test.sh 2>&1 | tail -3`
Expected: everything passes (52 existing + 33 new = 85).

- [ ] **Step 6: Commit**

```bash
git add Sources/ScribeCore/TranscriptionQueue.swift Tests/ScribeCoreTests/TranscriptionQueueTests.swift
git commit -m "Add the serial transcription queue

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: FluidAudio engine

**Files:**
- Modify: `Sources/ScribeTranscription/FluidAudioEngine.swift` (replace the placeholder)

**Interfaces:**
- Consumes: `SpeechEngine`, `TimedWord`, `SpeakerSegment`, `DiarizationOutcome`, `ScribeError` from ScribeCore. From FluidAudio 0.15.7: `AsrModels.downloadAndLoad(version: .v2)`, `AsrManager(config: .default)`, `AsrManager.loadModels(_:)`, `AsrManager.decoderLayerCount`, `TdtDecoderState.make(decoderLayers:)`, `AsrManager.transcribe(_:decoderState:)`, `buildWordTimings(from:)`, `OfflineDiarizerManager(config: .default)`, `prepareModels()`, `process(audio:)`, `OfflineDiarizationError.noSpeechDetected`, `TimedSpeakerSegment.speakerId/startTimeSeconds/endTimeSeconds` (Float).
- Produces: `public actor FluidAudioEngine: SpeechEngine { public init() }`.

No unit test: this is the one file that needs models. Task 9 exercises it end to end.

- [ ] **Step 1: Write the engine**

Replace the placeholder with:

```swift
import FluidAudio
import Foundation
import ScribeCore

/// The only type in Scribe that touches FluidAudio. Parakeet TDT v2 for
/// English ASR and the offline pyannote community-1 pipeline for diarization,
/// both as CoreML models on the Neural Engine. Models download once to
/// `~/Library/Application Support/FluidAudio/Models/`.
public actor FluidAudioEngine: SpeechEngine {
    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?

    public init() {}

    public func prepare() async throws {
        do {
            if asr == nil {
                let models = try await AsrModels.downloadAndLoad(version: .v2)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                asr = manager
            }
            if diarizer == nil {
                let manager = OfflineDiarizerManager(config: .default)
                try await manager.prepareModels()
                diarizer = manager
            }
        } catch {
            throw ScribeError.modelsUnavailable(Self.describe(error))
        }
    }

    public func transcribe(_ track: [Float]) async throws -> [TimedWord] {
        guard let asr else { throw ScribeError.modelsUnavailable("engine not prepared") }
        do {
            var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(track, decoderState: &state)
            return buildWordTimings(from: result.tokenTimings ?? []).map {
                TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
            }
        } catch {
            throw ScribeError.transcriptionFailed(Self.describe(error))
        }
    }

    public func diarize(_ track: [Float]) async throws -> DiarizationOutcome {
        guard let diarizer else { throw ScribeError.modelsUnavailable("engine not prepared") }
        do {
            let result = try await diarizer.process(audio: track)
            return .segments(result.segments.map {
                SpeakerSegment(
                    speakerID: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds))
            })
        } catch OfflineDiarizationError.noSpeechDetected {
            return .noSpeech
        } catch {
            throw ScribeError.transcriptionFailed(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | grep -E "error|warning: .*FluidAudioEngine|Build complete"`
Expected: `Build complete!`. If the compiler rejects a FluidAudio name, look it up in `.build/checkouts/FluidAudio/Sources/FluidAudio/` (ASR under `ASR/Parakeet/SlidingWindow/TDT/`, diarizer under `Diarizer/Offline/Core/`) rather than the README, and fix the call. If Swift 6 complains that `OfflineDiarizerManager` is not `Sendable` when calling `process`, the fix is to keep the call exactly as written inside the actor; do not mark anything `@unchecked Sendable`.

- [ ] **Step 3: Commit**

```bash
git add Sources/ScribeTranscription/FluidAudioEngine.swift
git commit -m "Add the FluidAudio speech engine

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: `scribe-cli transcribe`

**Files:**
- Modify: `Sources/scribe-cli/main.swift`

**Interfaces:**
- Consumes: `FluidAudioEngine` (Task 8), `TranscriptionPipeline` (Task 6).
- Produces: `scribe-cli transcribe <wav>` which writes `<wav basename>.md` next to the input and prints its path.

- [ ] **Step 1: Add the command**

In `Sources/scribe-cli/main.swift`, change the imports and usage line:

```swift
import Foundation
import ScribeCore
import ScribeTranscription

let usage = "usage: scribe-cli tap | devices | record <seconds> [directory] | transcribe <wav>"
```

Add a case before `default:`:

```swift
case "transcribe":
    guard args.count == 2 else { fail(usage) }
    let wavURL = URL(fileURLWithPath: args[1])
    Task {
        do {
            let engine = FluidAudioEngine()
            var started = Date()
            try await engine.prepare()
            FileHandle.standardError.write(Data(String(format: "models ready in %.1f s\n", Date().timeIntervalSince(started)).utf8))

            started = Date()
            let out = try await TranscriptionPipeline(engine: engine).run(wavURL)
            FileHandle.standardError.write(Data(String(format: "transcribed in %.1f s\n", Date().timeIntervalSince(started)).utf8))
            print(out.path)
            exit(0)
        } catch {
            fail("transcribe failed: \((error as? ScribeError)?.userMessage ?? "\(error)")")
        }
    }
    RunLoop.main.run()
```

- [ ] **Step 2: Build**

Run: `swift build --product scribe-cli 2>&1 | tail -2`
Expected: `Build complete!`.

- [ ] **Step 3: Run it end to end on a real recording**

There is no synthetic input that exercises both ASR and diarization, and recording one needs TCC consent, so use a recording the user already has. The 7 minute one below is the shortest with speech on both channels:

Run:
```bash
cp "$HOME/Music/Scribe/2026-09-14 13-44 Recording.wav" /tmp/scribe-smoke.wav
time .build/debug/scribe-cli transcribe /tmp/scribe-smoke.wav
head -6 /tmp/scribe-smoke.md
grep -c '^\*\*' /tmp/scribe-smoke.md
rm /tmp/scribe-smoke.wav /tmp/scribe-smoke.md
```
Expected: on first run, `models ready in` around 90 s (download plus CoreML compile) and a `Downloading` progress log from FluidAudio; on later runs under 1 s. `transcribed in` under 15 s for this 7 minute file. The head shows the `# Meeting 2026-09-14 13:44` title, `Duration: 7:07`, and a `Speakers:` line naming `Me` and three numbered speakers. The block count should be in the low tens (the spike got 15). A benign `E5RT encountered an STL exception` line on stderr at exit is expected.

Report timings and counts only. Do not paste transcript lines anywhere.

If running under a sandbox: the first run must be allowed network access and writes to `~/Library/Application Support/FluidAudio`.

- [ ] **Step 4: Commit**

```bash
git add Sources/scribe-cli/main.swift
git commit -m "Add scribe-cli transcribe

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: App integration

**Files:**
- Modify: `Sources/Scribe/AppState.swift`
- Modify: `Sources/Scribe/MenuView.swift`
- Modify: `Sources/Scribe/Notifier.swift`

**Interfaces:**
- Consumes: `TranscriptionQueue` (Task 7), `FluidAudioEngine` (Task 8), `SpeechEngine` (Task 3).
- Produces: `AppState.transcriptionStatus: String?` observed by the menu; `Notifier.transcriptSaved(_:)` and `Notifier.transcriptionFailed(_:)`.

There is no test target for the app; verification is the build plus the manual checks in Task 11.

- [ ] **Step 1: Notifier**

Add to `Notifier` after `recordingStopped`:

```swift
    func transcriptSaved(_ url: URL) {
        post(title: "Transcript saved", body: url.lastPathComponent)
    }

    func transcriptionFailed(_ error: ScribeError) {
        post(title: "Transcription failed", body: error.userMessage)
    }
```

Update the doc comment on the class to: `/// Posts Scribe's notifications: recording saved or stopped, transcript saved or failed.`

- [ ] **Step 2: AppState**

Change the imports to add `import ScribeTranscription`. Replace the stored properties and `init` with:

```swift
    let session: RecordingSession
    private(set) var lastError: ScribeError?
    private(set) var elapsedText = "0:00"
    /// One line for the menu: preparing, transcribing, or the last failure. Nil when idle.
    private(set) var transcriptionStatus: String?
    private var timer: Timer?
    private let notifier = Notifier()
    private var queue: TranscriptionQueue!

    init(session: RecordingSession = RecordingSession(), engine: any SpeechEngine = FluidAudioEngine()) {
        self.session = session
        session.onInterrupted = { [weak self] error, url in
            self?.recordingInterrupted(error, url: url)
        }
        AppDelegate.terminationHandler = { [weak self] in self?.finalizeForTermination() }
        notifier.requestAuthorization()

        queue = TranscriptionQueue(
            engine: engine,
            onStateChange: { [weak self] state in
                Task { @MainActor in self?.transcriptionStateChanged(state) }
            },
            onJobFinished: { [weak self] wavURL, result in
                Task { @MainActor in self?.transcriptionFinished(wavURL, result) }
            })
        Task { await queue.prepareModels() }
    }
```

Replace the two hook methods (the section currently headed `// MARK: - Hooks Task 11 fills in`) with:

```swift
    // MARK: - Recording outcomes

    private func recordingSaved(_ url: URL) {
        notifier.recordingSaved(url)
        enqueueTranscription(url)
    }

    private func recordingInterrupted(_ error: ScribeError, url: URL) {
        stopTimer()
        lastError = error
        notifier.recordingStopped(error)
        enqueueTranscription(url)
    }

    // MARK: - Transcription

    private func enqueueTranscription(_ url: URL) {
        Task { await queue.enqueue(url) }
    }

    private func transcriptionStateChanged(_ state: TranscriptionQueue.State) {
        switch state {
        case .preparingModels:
            transcriptionStatus = "Preparing transcription models…"
        case .idle:
            transcriptionStatus = nil
        case .transcribing(let url):
            transcriptionStatus = "Transcribing \(url.deletingPathExtension().lastPathComponent)…"
        case .failed(let url, let error):
            transcriptionStatus = "\(url.lastPathComponent): \(error.userMessage)"
        }
    }

    private func transcriptionFinished(_ wavURL: URL, _ result: Result<URL, ScribeError>) {
        switch result {
        case .success(let mdURL):
            notifier.transcriptSaved(mdURL)
        case .failure(let error):
            notifier.transcriptionFailed(error)
        }
    }
```

- [ ] **Step 3: MenuView**

Insert between the `if state.isRecording { ... } else { ... }` block and the `Divider()` that follows it:

```swift
        if let status = state.transcriptionStatus {
            Text(status)
        }
```

- [ ] **Step 4: Build the app**

Run: `swift build --product Scribe 2>&1 | grep -E "error|Build complete"`
Expected: `Build complete!`. If Swift 6 reports that `queue` is used before initialisation or that the closures capture `self` unsafely, the fix is the pattern above: `queue` is an implicitly unwrapped `var` assigned after every other stored property, and every closure hops to the main actor with `Task { @MainActor in ... }`.

- [ ] **Step 5: Bundle and launch**

Run: `scripts/bundle.sh debug`
Expected: the app launches. Open the menu: "Preparing transcription models…" is visible for a moment if the cache was deleted, or absent if Task 9 already populated it. Quit the app from its menu.

- [ ] **Step 6: Commit**

```bash
git add Sources/Scribe/AppState.swift Sources/Scribe/MenuView.swift Sources/Scribe/Notifier.swift
git commit -m "Transcribe every saved recording and show queue state in the menu

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Docs and manual smoke test

**Files:**
- Modify: `docs/smoke-test.md`
- Modify: `README.md`

- [ ] **Step 1: Smoke test checklist**

Add a section to `docs/smoke-test.md` before "Known gaps (phase 1.5)":

```markdown
## Transcription (phase 2)

Each check needs the user at the machine. `scripts/bundle.sh` first.

1. **First launch downloads models.** `rm -rf ~/Library/Application\ Support/FluidAudio`, launch. The menu shows "Preparing transcription models…" and the line clears within a couple of minutes. The cache directory is now about 470 MB.
2. **A stopped recording gets a transcript.** On a call with headphones, record 30 s in which both you and someone else speak, stop. Within about 10 s: "Transcript saved" notification, and `~/Music/Scribe/<name>.md` next to the WAV with a `**Me**` block and at least one `**Speaker 1**` block.
3. **Long recording, bounded memory.** `.build/debug/scribe-cli transcribe` on an hour-long recording finishes in under two minutes. Activity Monitor peak memory for `scribe-cli` stays under 1 GB.
4. **Recording while transcribing.** Stop a long recording, immediately start another. The menu shows the elapsed timer and "Transcribing …" together; the new recording saves normally; its transcript arrives after the first one's.
5. **Offline first launch heals.** Turn Wi-Fi off, delete the model cache, launch, record 10 s, stop. "Transcription failed" notification; the menu shows the filename with "Transcription models couldn't be loaded". Turn Wi-Fi on, record 10 s, stop. Transcript arrives and the failure line clears.

Expected noise: FluidAudio logs a benign `E5RT ... slice_by_index: zero shape error` line to the console at model teardown.
```

- [ ] **Step 2: README**

Update `README.md`:

- First paragraph: replace "Fully local. Transcription and diarization are planned as phase 2." with "Fully local. When a recording stops, Scribe transcribes it on-device (Parakeet TDT v2 via FluidAudio, with speaker diarization on the system-audio channel) and writes `<same name>.md` next to the WAV: your mic is `Me`, everyone else is `Speaker N`. Speech models (about 470 MB) download once on first launch to `~/Library/Application Support/FluidAudio/Models/`."
- Under "Command line", add: `.build/debug/scribe-cli transcribe path/to/recording.wav   # write recording.md next to it`
- Under "Layout", add: `- \`Sources/ScribeTranscription\` the FluidAudio adapter, the only target that imports it` and change the ScribeCore line to `- \`Sources/ScribeCore\` capture pipeline, recording state machine, transcription pipeline and queue; no UI, no ML dependency`.
- Under "Build and run", add a line: `The first \`swift build\` fetches FluidAudio and takes several minutes.`

- [ ] **Step 3: Full test run**

Run: `scripts/test.sh 2>&1 | tail -3`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add docs/smoke-test.md README.md
git commit -m "Document phase 2 transcription and its smoke checks

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 5: Hand the manual checks to the user**

Checks 1, 2, 4 and 5 need a call, notifications and Wi-Fi toggling; only the user can run them. Check 3 can be run by an agent with the sandbox disabled. Report which were run and their results; do not mark the phase done until the user has run theirs.
