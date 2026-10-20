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
    /// Model download or load failed. The string is the underlying error's description.
    case modelsUnavailable(String)
    /// Anything else that stops a transcript from being written.
    case transcriptionFailed(String)
    /// Registering or unregistering the login item failed. The string is the underlying error's description.
    case loginItemFailed(String)

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
            return "No microphone is available, so the recording was stopped."
        case .notRecording:
            return "Not recording."
        case .alreadyRecording:
            return "Already recording."
        case .modelsUnavailable(let detail):
            return "Transcription models couldn't be loaded (\(detail))."
        case .transcriptionFailed(let detail):
            return "Transcription failed (\(detail))."
        case .loginItemFailed(let detail):
            return "Couldn't change Launch at Login (\(detail))."
        }
    }
}
