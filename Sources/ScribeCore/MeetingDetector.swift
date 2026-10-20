import Foundation

/// Pure state machine for Teams meeting detection: events in, effects out.
///
/// It has no Core Audio, notification, or timer code. The caller performs
/// every `Effect` and reports their outcomes back as events
/// (`recordingStarted`, `recordingStopped`). A recording is only ever
/// started in response to `startPressed`, never straight from a mic event.
public struct MeetingDetector: Equatable, Sendable {
    public static let stopCountdown: TimeInterval = 15

    public enum Event: Equatable, Sendable {
        case teamsMic(Bool)
        case recordingStarted
        case recordingStopped
        case startPressed
        case continuePressed
        case countdownElapsed
    }

    public enum Effect: Equatable, Sendable {
        case postStartPrompt
        case removeStartPrompt
        case beginCountdown  // post stop notification + start 15 s timer
        case endCountdown  // remove stop notification + cancel timer
        case startRecording
        case stopRecording
    }

    /// nil until the first reading.
    private var mic: Bool?
    private var recording = false
    /// Teams has been seen using the mic during this recording, so its end may auto-stop.
    private var armed = false
    private var promptShowing = false
    private var countingDown = false
    /// Start was pressed before the first mic reading; decided by that reading.
    private var startPending = false

    public init() {}

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .teamsMic(let on):
            guard on != mic else { return [] }
            mic = on
            if on {
                if startPending {
                    startPending = false
                    return [.startRecording]
                }
                if countingDown {
                    countingDown = false
                    armed = true
                    return [.endCountdown]
                }
                if recording {
                    armed = true
                    return []
                }
                promptShowing = true
                return [.postStartPrompt]
            }
            if startPending {
                startPending = false
                return []
            }
            if promptShowing {
                promptShowing = false
                return [.removeStartPrompt]
            }
            if recording && armed && !countingDown {
                countingDown = true
                return [.beginCountdown]
            }
            return []

        case .recordingStarted:
            recording = true
            startPending = false
            armed = mic == true
            if promptShowing {
                promptShowing = false
                return [.removeStartPrompt]
            }
            return []

        case .recordingStopped:
            recording = false
            armed = false
            if countingDown {
                countingDown = false
                return [.endCountdown]
            }
            return []

        case .startPressed:
            if recording { return [] }
            switch mic {
            case nil:
                startPending = true
                return []
            case false?:
                return []
            case true?:
                promptShowing = false
                return [.removeStartPrompt, .startRecording]
            }

        case .continuePressed:
            guard countingDown else { return [] }
            countingDown = false
            armed = false
            return [.endCountdown]

        case .countdownElapsed:
            guard countingDown else { return [] }
            countingDown = false
            return [.endCountdown, .stopRecording]
        }
    }
}
