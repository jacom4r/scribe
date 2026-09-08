import CoreAudio
import Foundation

/// Keeps the system-audio tap clocking by doing silent output IO from this process.
///
/// A process tap has no clock of its own: an aggregate device containing one
/// delivers no input callbacks until some process performs output IO. The tap
/// includes Scribe itself, so a zero-filled output IO proc on the default output
/// device is enough to keep the aggregate running, and adds nothing audible.
/// Start before `CaptureEngine.start()`; stop after `CaptureEngine.stop()`.
///
/// `@unchecked Sendable`: all access is main-thread: the only owner is the
/// main-actor `RecordingSession` (via `LiveCapture`), and the default-output
/// listener runs on the main queue, so `deinit` also runs on main.
public final class OutputKeepAlive: @unchecked Sendable {
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    public init() {}

    public func start() throws {
        guard procID == nil else { return }
        let device = try CoreAudio.defaultOutputDevice()

        var created: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&created, device, nil) { _, _, _, outputData, _ in
            let list = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in list {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
        }
        guard status == noErr, let proc = created else {
            throw ScribeError.captureStartFailed(status)
        }
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            throw ScribeError.captureStartFailed(status)
        }
        deviceID = device
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
