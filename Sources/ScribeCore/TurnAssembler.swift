import Foundation

/// One block in the transcript: a speaker and their words joined by spaces.
public struct Turn: Equatable, Sendable {
    public var speaker: String
    public var text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// Phrase-first merge. Words are grouped into phrases inside each speaker's
/// own stream (a pause over `phraseGap` ends a phrase), phrases are ordered by
/// start time, and adjacent same-speaker phrases within `turnGap` become one
/// turn. Because phrases form before any interleaving, two people talking at
/// once produce whole phrases rather than word-by-word alternation.
public struct TurnAssembler: Sendable {
    public let phraseGap: TimeInterval
    public let turnGap: TimeInterval

    public init(phraseGap: TimeInterval = 0.7, turnGap: TimeInterval = 2.0) {
        self.phraseGap = phraseGap
        self.turnGap = turnGap
    }

    private struct Phrase {
        var speaker: String
        var start: TimeInterval
        var end: TimeInterval
        var words: [String]
    }

    public func assemble(_ words: [TimedWord]) -> [Turn] {
        // Speakers in order of first appearance, so ties in start time are deterministic.
        var speakers: [String] = []
        for word in words where !speakers.contains(word.speaker) {
            speakers.append(word.speaker)
        }

        var phrases: [Phrase] = []
        for speaker in speakers {
            let stream = words.filter { $0.speaker == speaker }.sorted { $0.start < $1.start }
            var current: Phrase?
            for word in stream {
                if var phrase = current, word.start - phrase.end <= phraseGap {
                    phrase.words.append(word.text)
                    phrase.end = max(phrase.end, word.end)
                    current = phrase
                } else {
                    if let phrase = current { phrases.append(phrase) }
                    current = Phrase(speaker: speaker, start: word.start, end: word.end, words: [word.text])
                }
            }
            if let phrase = current { phrases.append(phrase) }
        }

        // Stable by construction: ties keep the order phrases were appended in.
        let ordered = phrases.enumerated()
            .sorted { a, b in
                a.element.start == b.element.start ? a.offset < b.offset : a.element.start < b.element.start
            }
            .map(\.element)

        var turns: [Turn] = []
        var lastEnd = -TimeInterval.infinity
        for phrase in ordered {
            let text = phrase.words.joined(separator: " ")
            if let last = turns.last, last.speaker == phrase.speaker, phrase.start - lastEnd <= turnGap {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append(Turn(speaker: phrase.speaker, text: text))
            }
            lastEnd = max(lastEnd, phrase.end)
        }
        return turns
    }
}
