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
    var prepareDelayMilliseconds = 0
    private(set) var prepareCalls = 0
    private(set) var active = 0
    private(set) var maxActive = 0

    func setPrepareFailures(_ n: Int) { prepareFailuresRemaining = n }
    func setTranscribeFailures(_ n: Int) { transcribeFailuresRemaining = n }
    func setPrepareDelay(milliseconds: Int) { prepareDelayMilliseconds = milliseconds }

    func prepare() async throws {
        prepareCalls += 1
        if prepareDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(prepareDelayMilliseconds))
        }
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

    @Test func enqueueDuringLaunchPrepareWaitsAndPreparesOnce() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.engine.setPrepareDelay(milliseconds: 100)
        let a = h.wav("a")

        await h.queue.prepareModels()
        await h.queue.enqueue(a)          // arrives while the launch prepare is in flight

        try #require(await eventually { h.finished.all.count == 1 })
        #expect(await h.engine.prepareCalls == 1)
        if case .success = h.finished.all[0].1 {} else { Issue.record("expected success") }
        #expect(h.states.all == [.preparingModels, .transcribing(a), .idle])
    }

    @Test func prepareFailureAtLaunchRetriesOnEnqueue() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.engine.setPrepareFailures(1)

        await h.queue.prepareModels()
        #expect(await eventually { h.states.all == [.preparingModels, .idle] })

        let a = h.wav("a")
        await h.queue.enqueue(a)
        try #require(await eventually { h.finished.all.count == 1 })
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

        try #require(await eventually { h.finished.all.count == 2 })
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

        try #require(await eventually { h.finished.all.count == 1 })
        if case .failed(let url, .modelsUnavailable) = h.states.all.last { #expect(url == a) } else { Issue.record("expected failed(modelsUnavailable), got \(h.states.all)") }
    }
}
