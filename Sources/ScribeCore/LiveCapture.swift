import Foundation

/// One recording's worth of audio capture. `onInterrupted` is called on the
/// main thread when capture stops for a reason other than `stop()`.
public protocol AudioCapturing: AnyObject {
    var onInterrupted: (@Sendable (ScribeError) -> Void)? { get set }
    func start() throws
    func stop() throws
}

public protocol CaptureFactory {
    func makeCapture(url: URL) throws -> any AudioCapturing
}

/// The real thing: tap + aggregate + writer + engine for one file.
/// Teardown order matters: watchers, engine, keepalive, writer, aggregate, then tap.
final class LiveCapture: AudioCapturing {
    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private let writer: WavWriter
    private let engine: CaptureEngine
    private let relay = InterruptionRelay()
    private let keepAlive = OutputKeepAlive()
    private let inputWatcher: DefaultDeviceWatcher
    private let outputWatcher: DefaultDeviceWatcher

    var onInterrupted: (@Sendable (ScribeError) -> Void)? {
        didSet { relay.handler = onInterrupted }
    }

    init(url: URL) throws {
        let tap = try ProcessTap()
        let aggregate = try AggregateDevice(tap: tap)
        let writer = try WavWriter(url: url, inputSampleRate: aggregate.sampleRate)
        self.tap = tap
        self.aggregate = aggregate
        self.writer = writer
        self.engine = CaptureEngine(
            deviceID: aggregate.deviceID, layout: aggregate.layout, writer: writer, relay: relay)

        // Both closures capture the objects they use, not `self`, which is not
        // fully initialized here.
        let relay = self.relay
        self.inputWatcher = .defaultInput {
            relay.fire(.inputDeviceChanged)
        }
        // The keepalive is pinned to the output device it started on, so a new
        // default output would stall the aggregate. Restarting it moves the
        // silent IO proc to the new device. Output-device changes are not
        // interruptions, so a successful restart keeps the relay quiet; but a
        // keepalive that cannot re-arm means the aggregate has lost its clock,
        // so that case is reported and the recording stops. The capture is weak
        // so a notification still queued on the main queue as `LiveCapture` is
        // torn down cannot start an IO proc nothing will stop. No locking: this
        // block runs on the main queue and `LiveCapture` only touches
        // `keepAlive` on the main thread.
        let keepAlive = self.keepAlive
        self.outputWatcher = .defaultOutput { [weak keepAlive] in
            guard let keepAlive else { return }
            keepAlive.stop()
            do {
                try keepAlive.start()
            } catch let error as ScribeError {
                relay.fire(error)
            } catch {
                relay.fire(.captureStartFailed(-1))
            }
        }
    }

    func start() throws {
        try keepAlive.start()
        try engine.start()
        try inputWatcher.start()
        try outputWatcher.start()
    }

    func stop() throws {
        inputWatcher.stop()
        outputWatcher.stop()
        engine.stop()
        keepAlive.stop()
        defer {
            aggregate = nil
            tap = nil
        }
        try writer.close()
    }

    deinit {
        inputWatcher.stop()
        outputWatcher.stop()
        engine.stop()
        keepAlive.stop()
        try? writer.close()
        aggregate = nil
        tap = nil
    }
}

public struct LiveCaptureFactory: CaptureFactory {
    public init() {}

    public func makeCapture(url: URL) throws -> any AudioCapturing {
        try LiveCapture(url: url)
    }
}
