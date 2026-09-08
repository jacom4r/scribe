import AudioToolbox
import CoreAudio
import Foundation

/// Delivers at most one interruption to `handler`, always on the main queue.
/// Safe to call from any thread, including the audio thread on its failure path.
public final class InterruptionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var storedHandler: (@Sendable (ScribeError) -> Void)?

    public init() {}

    public var handler: (@Sendable (ScribeError) -> Void)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    public func fire(_ error: ScribeError) {
        let first: Bool = lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
        guard first else { return }
        let handler = self.handler
        DispatchQueue.main.async { handler?(error) }
    }
}

/// State touched on the real-time audio thread. Everything here is allocated
/// before `start()` and never resized.
private final class IOState: @unchecked Sendable {
    let layout: InputLayout
    let writer: WavWriter
    let scratch: StereoBuffer
    let relay: InterruptionRelay
    var failed = false

    init(layout: InputLayout, writer: WavWriter, relay: InterruptionRelay, capacityFrames: Int) {
        self.layout = layout
        self.writer = writer
        self.relay = relay
        self.scratch = StereoBuffer(capacityFrames: capacityFrames)
    }

    func process(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0 else { return }
        let first = list[0]
        let channels = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (channels * MemoryLayout<Float>.size)

        let written = downmix(list, frames: frames, layout: layout, into: scratch.samples)
        guard written > 0 else { return }

        let status = writer.writeAsync(frames: UInt32(written), scratch.bufferList(frames: written))
        if status != noErr && !failed {
            failed = true
            relay.fire(.writeFailed(status))
        }
    }
}

/// Runs an IO proc on a device, downmixes every input callback to stereo, and
/// streams it to a `WavWriter`. Write failures are reported through the relay.
public final class CaptureEngine {
    private let deviceID: AudioDeviceID
    private let state: IOState
    private var procID: AudioDeviceIOProcID?

    public init(deviceID: AudioDeviceID, layout: InputLayout, writer: WavWriter,
                relay: InterruptionRelay, capacityFrames: Int = 8192) {
        self.deviceID = deviceID
        self.state = IOState(layout: layout, writer: writer, relay: relay, capacityFrames: capacityFrames)
    }

    public func start() throws {
        guard procID == nil else { return }
        try state.writer.prime()

        let state = self.state
        var created: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&created, deviceID, nil) { _, inputData, _, _, _ in
            state.process(inputData)
        }
        guard status == noErr, let proc = created else {
            throw ScribeError.captureStartFailed(status)
        }

        status = AudioDeviceStart(deviceID, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, proc)
            throw ScribeError.captureStartFailed(status)
        }
        procID = proc
    }

    public func stop() {
        guard let proc = procID else { return }
        AudioDeviceStop(deviceID, proc)
        AudioDeviceDestroyIOProcID(deviceID, proc)
        procID = nil
    }

    deinit {
        stop()
    }
}
