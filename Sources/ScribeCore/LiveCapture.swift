import Foundation

/// One recording's worth of audio capture. `onInterrupted` is called on the
/// main thread when capture stops for a reason other than `stop()`.
/// `onInputChanged` is called on the main thread with the new microphone's name
/// after the capture has swapped to a different input device.
public protocol AudioCapturing: AnyObject {
    var onInterrupted: (@Sendable (ScribeError) -> Void)? { get set }
    var onInputChanged: (@Sendable (String) -> Void)? { get set }
    /// The microphone being recorded right now.
    var micName: String { get }
    func start() throws
    func stop() throws
}

public protocol CaptureFactory {
    func makeCapture(url: URL) throws -> any AudioCapturing
}

/// The real thing: tap + writer + keepalive for one file, with the swappable
/// aggregate and engine delegated to `InputSwapController`.
/// Teardown order matters: watchers, controller, keepalive, writer, then tap.
final class LiveCapture: AudioCapturing {
    private var tap: ProcessTap?
    private let writer: WavWriter
    private let controller: InputSwapController
    private let relay = InterruptionRelay()
    private let keepAlive = OutputKeepAlive()
    private var inputWatcher: DefaultDeviceWatcher?
    private let outputWatcher: DefaultDeviceWatcher

    var onInterrupted: (@Sendable (ScribeError) -> Void)? {
        didSet { relay.handler = onInterrupted }
    }

    var onInputChanged: (@Sendable (String) -> Void)? {
        didSet {
            let handler = onInputChanged
            let controller = self.controller
            MainActor.assumeIsolated {
                controller.onInputChanged = { name in handler?(name) }
            }
        }
    }

    var micName: String {
        let controller = self.controller
        return MainActor.assumeIsolated { controller.micName }
    }

    init(url: URL) throws {
        let tap = try ProcessTap()
        // The writer's rate is a placeholder until the first graph reports the
        // real one; `InputSwapController.start()` retunes it before any audio
        // is written.
        let writer = try WavWriter(url: url, inputSampleRate: WavWriter.fileSampleRate)
        self.tap = tap
        self.writer = writer

        let relay = self.relay
        // `LiveInputGraphBuilder` is a plain (non-actor) struct, so building
        // it here needs no actor crossing. Only `InputSwapController`'s own
        // init is `@MainActor`; `LiveCapture.init` is nonisolated (a plain
        // class), so that one call crosses via `MainActor.assumeIsolated` —
        // the same escape hatch `RecordingSession.start()` uses for the
        // symmetric case. It is sound here because `LiveCapture.init` is only
        // ever reached through `RecordingSession.start()`, itself
        // `@MainActor`, so this always runs on the main thread already; the
        // builder value passed in is not touched again until the controller
        // (also confined to the main actor from here on) calls it.
        let builder = LiveInputGraphBuilder(tap: tap, writer: writer, relay: relay)
        let controller = MainActor.assumeIsolated {
            InputSwapController(builder: builder, writer: writer)
        }
        self.controller = controller

        // Captures the objects it uses, not `self`, which is not fully
        // initialized here. The keepalive is pinned to the output device it
        // started on, so a new default output would stall the aggregate.
        // Restarting it moves the silent IO proc to the new device.
        // Output-device changes are not interruptions, so a successful
        // restart keeps the relay quiet; a keepalive that cannot re-arm means
        // the aggregate has lost its clock, so that case is reported and the
        // recording stops.
        //
        // Captured as `[weak keepAlive]`, not strong: a default-output
        // notification can still be sitting on the main queue when
        // `LiveCapture` is torn down, and by the time it runs there would be
        // nothing left to stop the IO proc it might start. Weakly capturing
        // `keepAlive` means a notification that fires after teardown finds it
        // already gone and does nothing. No locking is needed either: this
        // block runs on the main queue, and `LiveCapture` only ever touches
        // `keepAlive` from the main thread.
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

        MainActor.assumeIsolated {
            controller.onFailure = { [weak relay] error in relay?.fire(error) }
        }
    }

    func start() throws {
        try keepAlive.start()
        // Bound to a local first: capturing `self` (implied by `controller`
        // alone) in the `@MainActor` closure below would let the "sending"
        // checker see `self` as handed to the main actor while `LiveCapture`,
        // a plain nonisolated class, keeps using it right after — a false
        // positive here since everything genuinely runs on the main thread,
        // but the local avoids the diagnostic without weakening the check
        // elsewhere.
        let controller = self.controller
        try MainActor.assumeIsolated { try controller.start() }

        // Created here rather than in `init` so the closure can reach the
        // controller. Delivers on the main queue, which is where the
        // controller expects to be called.
        let watcher = DefaultDeviceWatcher.defaultInput {
            MainActor.assumeIsolated { controller.handleInputChange() }
        }
        try watcher.start()
        inputWatcher = watcher

        try outputWatcher.start()
    }

    func stop() throws {
        inputWatcher?.stop()
        inputWatcher = nil
        outputWatcher.stop()
        let controller = self.controller
        MainActor.assumeIsolated { controller.stop() }
        keepAlive.stop()
        defer { tap = nil }
        try writer.close()
    }

    deinit {
        inputWatcher?.stop()
        outputWatcher.stop()
        let controller = self.controller
        MainActor.assumeIsolated { controller.stop() }
        keepAlive.stop()
        try? writer.close()
        tap = nil
    }
}

public struct LiveCaptureFactory: CaptureFactory {
    public init() {}

    public func makeCapture(url: URL) throws -> any AudioCapturing {
        try LiveCapture(url: url)
    }
}
