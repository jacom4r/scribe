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
/// Teardown order matters: engine, keepalive, writer, aggregate, then tap.
final class LiveCapture: AudioCapturing {
    private var tap: ProcessTap?
    private var aggregate: AggregateDevice?
    private let writer: WavWriter
    private let engine: CaptureEngine
    private let relay = InterruptionRelay()
    private let keepAlive = OutputKeepAlive()

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
    }

    func start() throws {
        try keepAlive.start()
        try engine.start()
    }

    func stop() throws {
        engine.stop()
        keepAlive.stop()
        defer {
            aggregate = nil
            tap = nil
        }
        try writer.close()
    }

    deinit {
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
