import Foundation
import Testing

@testable import ScribeCore

final class FakeCapture: AudioCapturing {
    var onInterrupted: (@Sendable (ScribeError) -> Void)?
    var onInputChanged: (@Sendable (String) -> Void)?
    var micName = "Fake Microphone"
    var started = false
    var stopped = false
    var startError: ScribeError?
    /// Set by `FakeFactory`, so a failing `start()` can leave a real file
    /// behind the way the live capture would.
    var url: URL?

    func start() throws {
        if let startError {
            if let url { try? Data().write(to: url) }
            throw startError
        }
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
        // Create the file before failing: the live factory opens the WAV as
        // part of construction, so a later throw can leave one on disk.
        if let makeError {
            try? Data().write(to: url)
            throw makeError
        }
        capture.url = url
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

    @Test func factoryFailureRemovesFile() throws {
        let (session, factory, _) = makeSession()
        factory.makeError = .permissionDenied

        #expect(throws: ScribeError.permissionDenied) { try session.start() }

        let url = try #require(factory.lastURL)
        #expect(!FileManager.default.fileExists(atPath: url.path))
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

    @Test func publishesTheMicNameWhileRecording() throws {
        let (session, factory, _) = makeSession()
        factory.capture.micName = "AirPods"

        try session.start()

        #expect(session.micName == "AirPods")
    }

    @Test func updatesTheMicNameOnSwap() throws {
        let (session, factory, _) = makeSession()
        factory.capture.micName = "AirPods"
        try session.start()

        factory.capture.onInputChanged?("MacBook Pro Microphone")

        #expect(session.micName == "MacBook Pro Microphone")
        #expect(session.isRecording)
    }

    @Test func clearsTheMicNameOnStop() throws {
        let (session, factory, _) = makeSession()
        factory.capture.micName = "AirPods"
        try session.start()

        _ = try session.stop()

        #expect(session.micName == nil)
    }

    @Test func clearsTheMicNameWhenASwapFails() throws {
        let (session, factory, _) = makeSession()
        factory.capture.micName = "AirPods"
        try session.start()

        // A swap that cannot complete reports through the same interruption
        // path as any other failure.
        factory.capture.onInterrupted?(.aggregateCreationFailed(-1))

        #expect(session.micName == nil)
        #expect(session.state == .idle)
    }
}
