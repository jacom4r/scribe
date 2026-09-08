import Foundation

/// Every failure the recorder can report. `userMessage` is what the menu and
/// notifications show; keep it one short sentence.
public enum ScribeError: Error, Equatable, Sendable {
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case captureStartFailed(OSStatus)
    case noInputDevice
    case writeFailed(OSStatus)
    case inputDeviceChanged
    case notRecording
    case alreadyRecording

    public var userMessage: String {
        switch self {
        case .permissionDenied:
            return "Scribe needs System Audio Recording permission."
        case .tapCreationFailed(let status):
            return "Couldn't tap system audio (error \(status))."
        case .aggregateCreationFailed(let status):
            return "Couldn't combine mic and system audio (error \(status))."
        case .captureStartFailed(let status):
            return "Couldn't start audio capture (error \(status))."
        case .noInputDevice:
            return "No microphone is available."
        case .writeFailed(let status):
            return "Couldn't write the recording (error \(status))."
        case .inputDeviceChanged:
            return "The microphone changed, so the recording was stopped."
        case .notRecording:
            return "Not recording."
        case .alreadyRecording:
            return "Already recording."
        }
    }
}
