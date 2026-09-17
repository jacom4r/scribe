import CoreAudio
import Foundation
import Testing

@testable import ScribeCore

final class FakeInputGraph: InputGraph {
    let micDeviceID: AudioDeviceID
    let micName: String
    let sampleRate: Double
    var started = false
    var stopped = false
    var startError: ScribeError?

    init(micDeviceID: AudioDeviceID, micName: String, sampleRate: Double = 48_000) {
        self.micDeviceID = micDeviceID
        self.micName = micName
        self.sampleRate = sampleRate
    }

    func start() throws {
        if let startError { throw startError }
        started = true
    }

    func stop() {
        stopped = true
    }
}

/// Hands out a queued sequence of graphs, recording how many were asked for.
final class FakeGraphBuilder: InputGraphBuilding {
    var queue: [FakeInputGraph] = []
    var built: [FakeInputGraph] = []
    var makeError: ScribeError?
    /// Whether `built.last` (the previously built graph, if any) had already
    /// been stopped at the moment this build was asked for. Empty for the
    /// first build, since there is no previous graph.
    var previousStoppedAtBuild: [Bool] = []

    func makeGraph() throws -> any InputGraph {
        if let makeError { throw makeError }
        if let previous = built.last {
            previousStoppedAtBuild.append(previous.stopped)
        }
        let graph = queue.isEmpty
            ? FakeInputGraph(micDeviceID: 1, micName: "Fallback")
            : queue.removeFirst()
        built.append(graph)
        return graph
    }
}

@MainActor
@Suite struct InputSwapTests {
    private func tempWriter() throws -> (WavWriter, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-swap-\(UUID().uuidString).wav")
        return (try WavWriter(url: url, inputSampleRate: 48_000), url)
    }

    @Test func startBuildsAndStartsAGraph() throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        let controller = InputSwapController(
            builder: builder, writer: writer, coalesceWindow: 0.01,
            currentInputDevice: { 7 })

        try controller.start()

        #expect(builder.built.count == 1)
        #expect(builder.built[0].started)
        #expect(controller.micName == "AirPods")
    }

    @Test func stopStopsTheGraph() throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        let controller = InputSwapController(
            builder: builder, writer: writer, coalesceWindow: 0.01,
            currentInputDevice: { 7 })

        try controller.start()
        controller.stop()

        #expect(builder.built[0].stopped)
    }

    /// Helper: a controller wired to `builder` whose reported default input
    /// device can be changed by the test.
    private func makeController(_ builder: FakeGraphBuilder,
                                _ writer: WavWriter,
                                device: @escaping () -> AudioDeviceID)
        -> InputSwapController {
        InputSwapController(builder: builder, writer: writer,
                            coalesceWindow: 0.01, currentInputDevice: { device() })
    }

    @Test func rebuildsTheGraphWhenTheDefaultInputChanges() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [
            FakeInputGraph(micDeviceID: 7, micName: "AirPods"),
            FakeInputGraph(micDeviceID: 9, micName: "MacBook Pro Microphone"),
        ]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })
        var announced: [String] = []
        controller.onInputChanged = { announced.append($0) }

        try controller.start()
        device = 9
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(builder.built.count == 2)
        #expect(builder.built[0].stopped)
        #expect(builder.built[1].started)
        #expect(controller.micName == "MacBook Pro Microphone")
        #expect(announced == ["MacBook Pro Microphone"])
        // The old graph must be stopped before the new one is built — that
        // ordering is what makes `WavWriter.setInputSampleRate` safe.
        #expect(builder.previousStoppedAtBuild == [true])
    }

    @Test func ignoresAChangeThatResolvesToTheSameDevice() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        let controller = makeController(builder, writer, device: { 7 })

        try controller.start()
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(builder.built.count == 1)
        #expect(!builder.built[0].stopped)
    }

    @Test func coalescesABurstIntoOneRebuild() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [
            FakeInputGraph(micDeviceID: 7, micName: "AirPods"),
            FakeInputGraph(micDeviceID: 9, micName: "MacBook Pro Microphone"),
        ]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })

        try controller.start()
        device = 9
        controller.handleInputChange()
        controller.handleInputChange()
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(builder.built.count == 2)
    }

    @Test func retunesTheWriterToTheNewGraphsRate() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [
            FakeInputGraph(micDeviceID: 7, micName: "AirPods", sampleRate: 24_000),
            FakeInputGraph(micDeviceID: 9, micName: "Built-in", sampleRate: 48_000),
        ]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })

        try controller.start()
        #expect(writer.inputSampleRate == 24_000)

        device = 9
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(writer.inputSampleRate == 48_000)
    }

    @Test func aBuilderFailureReportsOneInterruption() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })
        var failures: [ScribeError] = []
        controller.onFailure = { failures.append($0) }

        try controller.start()
        builder.makeError = .aggregateCreationFailed(-1)
        device = 9
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(failures == [.aggregateCreationFailed(-1)])
    }

    @Test func aStartFailureOnTheNewGraphReportsOneInterruption() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        let replacement = FakeInputGraph(micDeviceID: 9, micName: "Built-in")
        replacement.startError = .captureStartFailed(-2)
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods"), replacement]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })
        var failures: [ScribeError] = []
        controller.onFailure = { failures.append($0) }

        try controller.start()
        device = 9
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(failures == [.captureStartFailed(-2)])
    }

    @Test func aVanishedInputDeviceReportsInputDeviceChanged() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [FakeInputGraph(micDeviceID: 7, micName: "AirPods")]
        var present = true
        let controller = InputSwapController(
            builder: builder, writer: writer, coalesceWindow: 0.01,
            currentInputDevice: {
                if present { return 7 }
                throw ScribeError.noInputDevice
            })
        var failures: [ScribeError] = []
        controller.onFailure = { failures.append($0) }

        try controller.start()
        present = false
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(failures == [.inputDeviceChanged])
    }

    @Test func aTransientNoDeviceReadingMidBurstDoesNotEndTheRecording() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [
            FakeInputGraph(micDeviceID: 7, micName: "AirPods"),
            FakeInputGraph(micDeviceID: 9, micName: "MacBook Pro Microphone"),
        ]
        var reads = 0
        let controller = InputSwapController(
            builder: builder, writer: writer, coalesceWindow: 0.01,
            currentInputDevice: {
                reads += 1
                // The first read (at notification time) finds no device, as
                // can happen mid-burst; the device is back by the time the
                // coalescing window fires.
                if reads == 1 { throw ScribeError.noInputDevice }
                return 9
            })
        var failures: [ScribeError] = []
        controller.onFailure = { failures.append($0) }

        try controller.start()
        controller.handleInputChange()
        try await Task.sleep(for: .milliseconds(80))

        #expect(failures.isEmpty)
        #expect(builder.built.count == 2)
        #expect(controller.micName == "MacBook Pro Microphone")
    }

    @Test func stopCancelsAPendingSwap() async throws {
        let (writer, url) = try tempWriter()
        defer { try? FileManager.default.removeItem(at: url) }
        let builder = FakeGraphBuilder()
        builder.queue = [
            FakeInputGraph(micDeviceID: 7, micName: "AirPods"),
            FakeInputGraph(micDeviceID: 9, micName: "Built-in"),
        ]
        var device: AudioDeviceID = 7
        let controller = makeController(builder, writer, device: { device })

        try controller.start()
        device = 9
        controller.handleInputChange()
        controller.stop()
        try writer.close()
        try await Task.sleep(for: .milliseconds(80))

        // No second graph was built, and nothing touched the closed writer.
        #expect(builder.built.count == 1)
    }
}
