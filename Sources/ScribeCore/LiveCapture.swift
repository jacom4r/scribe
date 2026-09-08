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
        // silent IO proc to the new device; this is not an interruption, so the
        // relay stays quiet. No locking: this block runs on the main queue and
        // `LiveCapture` only touches `keepAlive` on the main thread.
        let keepAlive = self.keepAlive
        self.outputWatcher = .defaultOutput {
            keepAlive.stop()
            try? keepAlive.start()
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
