import Foundation

/// One recognised word with its time span, and the speaker label the
/// pipeline assigns ("Me", "Speaker 1", ...). Engines leave `speaker` empty.
public struct TimedWord: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: String

    public init(text: String, start: TimeInterval, end: TimeInterval, speaker: String = "") {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// One span of speech attributed to an engine-defined speaker id (e.g. "S1").
public struct SpeakerSegment: Equatable, Sendable {
    public var speakerID: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerID: String, start: TimeInterval, end: TimeInterval) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

public enum DiarizationOutcome: Equatable, Sendable {
    case segments([SpeakerSegment])
    /// The diarizer found no speech at all. Not an error.
    case noSpeech
}

/// What the pipeline needs from a speech stack. Tracks are 16 kHz mono Float32.
public protocol SpeechEngine: Sendable {
    /// Downloads and loads models if needed. Idempotent. Throws `ScribeError.modelsUnavailable`.
    func prepare() async throws
    /// Recognised words with times. Throws `ScribeError.transcriptionFailed`.
    func transcribe(_ track: [Float]) async throws -> [TimedWord]
    /// Speaker segments. Returns `.noSpeech` rather than throwing when there is nothing to diarize.
    func diarize(_ track: [Float]) async throws -> DiarizationOutcome
}
