import Foundation
import Observation

/// The recorder's state machine. Main-actor only.
@MainActor
@Observable
public final class RecordingSession {
    public enum State: Equatable, Sendable {
        case idle
        case recording(since: Date, url: URL)
        case finalizing
    }

    public private(set) var state: State = .idle
    /// The microphone currently being recorded, or nil when idle.
    public private(set) var micName: String?
    /// Read only by `start()`, so replacing it mid-recording affects the next recording.
    public var store: RecordingStore

    /// Called when a recording stops on its own (device change, write failure).
    /// Not called for a user-initiated `stop()`.
    public var onInterrupted: ((ScribeError, URL) -> Void)?

    private let factory: any CaptureFactory
    private var capture: (any AudioCapturing)?

    public init(store: RecordingStore, factory: any CaptureFactory) {
        self.store = store
        self.factory = factory
    }

    public convenience init(store: RecordingStore = .default()) {
        self.init(store: store, factory: LiveCaptureFactory())
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    public func elapsed(at now: Date = Date()) -> TimeInterval {
        if case .recording(let since, _) = state { return now.timeIntervalSince(since) }
        return 0
    }

    @discardableResult
    public func start(now: Date = Date()) throws -> URL {
        guard case .idle = state else { throw ScribeError.alreadyRecording }

        let url = try store.newRecordingURL(at: now)

        // `makeCapture` is inside the `do` so that a failure there — it may
        // already have created the file — unwinds the file on disk too.
        // `made` stays nil in that case, so there is nothing to stop.
        var made: (any AudioCapturing)?
        do {
            let capture = try factory.makeCapture(url: url)
            made = capture
            capture.onInterrupted = { [weak self] error in
                MainActor.assumeIsolated {
                    self?.handleInterruption(error)
                }
            }
            capture.onInputChanged = { [weak self] name in
                MainActor.assumeIsolated {
                    self?.micName = name
                }
            }
            try capture.start()
        } catch {
            try? made?.stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        self.capture = made
        micName = made?.micName
        state = .recording(since: now, url: url)
        return url
    }

    @discardableResult
    public func stop() throws -> URL {
        guard case .recording(_, let url) = state, let capture else {
            throw ScribeError.notRecording
        }
        state = .finalizing
        self.capture = nil
        micName = nil
        defer { state = .idle }
        try capture.stop()
        return url
    }

    private func handleInterruption(_ error: ScribeError) {
        guard case .recording(_, let url) = state else { return }
        _ = try? stop()
        onInterrupted?(error, url)
    }
}
