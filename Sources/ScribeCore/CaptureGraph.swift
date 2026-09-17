import CoreAudio
import Foundation

/// One microphone generation's worth of capture: an aggregate device built
/// around the current default input, plus the IO proc driving it. Rebuilt on
/// every input device swap. The tap and writer it feeds outlive it.
protocol InputGraph: AnyObject {
    /// The default input device this graph was built around. The swap policy
    /// compares it against the current default to ignore no-op notifications.
    var micDeviceID: AudioDeviceID { get }
    var micName: String { get }
    var sampleRate: Double { get }
    func start() throws
    func stop()
}

protocol InputGraphBuilding {
    /// Builds a graph around whatever the default input device is right now.
    func makeGraph() throws -> any InputGraph
}

/// The real thing: aggregate + engine, built from a tap and writer it does not
/// own. Releasing the aggregate destroys it; the tap survives for the next
/// graph, which is why a swap never re-creates the tap or re-prompts for the
/// System Audio permission.
final class LiveInputGraph: InputGraph {
    let micDeviceID: AudioDeviceID
    let micName: String
    let sampleRate: Double
    private var aggregate: AggregateDevice?
    private let engine: CaptureEngine

    init(tap: ProcessTap, writer: WavWriter, relay: InterruptionRelay) throws {
        let aggregate = try AggregateDevice(tap: tap)
        self.aggregate = aggregate
        micDeviceID = aggregate.micDeviceID
        micName = aggregate.micName
        sampleRate = aggregate.sampleRate
        engine = CaptureEngine(
            deviceID: aggregate.deviceID, layout: aggregate.layout,
            writer: writer, relay: relay)
    }

    func start() throws {
        try engine.start()
    }

    /// Engine first, then the aggregate: `CaptureEngine.stop()` is synchronous,
    /// so no IO proc is running by the time the device goes away.
    func stop() {
        engine.stop()
        aggregate = nil
    }

    deinit {
        stop()
    }
}

/// `@unchecked Sendable` because `tap` is not `Sendable`, and this value must
/// cross into `InputSwapController`'s `@MainActor` init from `LiveCapture`'s
/// nonisolated one. This is safe because the builder value itself is only
/// ever created and used on the main thread: it crosses into exactly one
/// `MainActor.assumeIsolated` closure, which traps if that closure is ever
/// reached off the main thread. Its members do not introduce a second thread
/// either: `writer` and `relay` are `WavWriter` and `InterruptionRelay`,
/// which are already `@unchecked Sendable` under their own documented
/// contracts (the real-time audio thread reaches them separately, through
/// `CaptureEngine`, not through this builder), and `tap` is a `ProcessTap`,
/// whose stored properties are all immutable.
struct LiveInputGraphBuilder: InputGraphBuilding, @unchecked Sendable {
    let tap: ProcessTap
    let writer: WavWriter
    let relay: InterruptionRelay

    func makeGraph() throws -> any InputGraph {
        try LiveInputGraph(tap: tap, writer: writer, relay: relay)
    }
}
