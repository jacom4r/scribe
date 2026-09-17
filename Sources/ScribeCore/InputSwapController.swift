import CoreAudio
import Foundation

/// Owns the current `InputGraph` and, from Task 4, the policy for replacing it
/// when the default input device changes.
///
/// Main-actor isolated: `DefaultDeviceWatcher` delivers on the main queue and
/// every mutation here happens in response to one, so no locking is needed.
/// It deliberately holds no Core Audio objects of its own — the tap and writer
/// belong to `LiveCapture` — which is what lets it be tested with a fake
/// builder and no audio hardware.
@MainActor
final class InputSwapController {
    /// Called with the new mic's name after a successful swap.
    var onInputChanged: ((String) -> Void)?
    /// Called when the recording cannot continue. Routed to the interruption
    /// relay by `LiveCapture`, which stops and saves the partial file.
    var onFailure: ((ScribeError) -> Void)?

    private(set) var micName = ""

    private let builder: any InputGraphBuilding
    private let writer: WavWriter
    private let coalesceWindow: TimeInterval
    private let currentInputDevice: () throws -> AudioDeviceID
    private var graph: (any InputGraph)?
    private var pendingSwap: DispatchWorkItem?

    init(builder: any InputGraphBuilding,
         writer: WavWriter,
         coalesceWindow: TimeInterval = 0.3,
         currentInputDevice: @escaping () throws -> AudioDeviceID = CoreAudio.defaultInputDevice) {
        self.builder = builder
        self.writer = writer
        self.coalesceWindow = coalesceWindow
        self.currentInputDevice = currentInputDevice
    }

    func start() throws {
        guard graph == nil else { return }
        let graph = try builder.makeGraph()
        try writer.setInputSampleRate(graph.sampleRate)
        try graph.start()
        self.graph = graph
        micName = graph.micName
    }

    func stop() {
        pendingSwap?.cancel()
        pendingSwap = nil
        graph?.stop()
        graph = nil
    }

    /// Called from the default-input watcher on the main queue.
    ///
    /// The watcher fires on any change to the property, including ones that
    /// resolve back to the device we are already on, so the cheap filter runs
    /// first and the device is re-resolved again after the window. A read
    /// that throws here is treated as "possibly a different device", not as
    /// a failure: an AirPods connect/disconnect burst can make an early
    /// notification in the sequence briefly resolve to "no default input"
    /// before the replacement device appears, and reporting failure on that
    /// reading would end the recording over a state that never persists.
    /// The coalesced swap is scheduled the same as for a different device;
    /// `performSwap` re-resolves after the window and is what actually
    /// reports `.inputDeviceChanged` if there is still no device by then.
    func handleInputChange() {
        guard let graph, pendingSwap == nil else { return }
        if let current = try? currentInputDevice(), current == graph.micDeviceID {
            return
        }

        // The window is fixed from the first notification and is deliberately
        // not extended by later ones: a device that flaps continuously would
        // otherwise postpone the swap indefinitely, leaving the recording on a
        // mic that is already gone.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSwap = nil
                self.performSwap()
            }
        }
        pendingSwap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceWindow, execute: work)
    }

    /// Stop, rebuild, retune, start. Any failure falls back to stop-and-save,
    /// which is never worse than phase 1's stop-on-change.
    private func performSwap() {
        guard let old = graph else { return }
        guard let current = try? currentInputDevice() else {
            onFailure?(.inputDeviceChanged)
            return
        }
        guard current != old.micDeviceID else { return }

        // Synchronous, so no `writeAsync` is in flight once it returns — which
        // is what makes `setInputSampleRate` safe below.
        old.stop()
        graph = nil

        do {
            let next = try builder.makeGraph()
            try writer.setInputSampleRate(next.sampleRate)
            try next.start()
            graph = next
            micName = next.micName
            onInputChanged?(next.micName)
        } catch let error as ScribeError {
            onFailure?(error)
        } catch {
            onFailure?(.captureStartFailed(-1))
        }
    }
}
