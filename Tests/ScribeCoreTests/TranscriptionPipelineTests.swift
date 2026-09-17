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
