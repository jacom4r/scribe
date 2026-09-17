import Foundation
import Testing
@testable import ScribeCore

@Suite struct TurnAssemblerTests {
    private func w(_ text: String, _ start: TimeInterval, _ end: TimeInterval, _ speaker: String) -> TimedWord {
        TimedWord(text: text, start: start, end: end, speaker: speaker)
    }

    @Test func overlappingSpeakersYieldWholePhrases() {
        // A talks 0-3 s; B interjects 1-2 s. Naive time-ordering would split A's sentence.
        let words = [
            w("one", 0.0, 0.5, "A"), w("two", 0.5, 1.0, "A"), w("three", 1.0, 1.5, "A"),
            w("four", 1.5, 2.0, "A"), w("five", 2.0, 2.5, "A"), w("six", 2.5, 3.0, "A"),
            w("yeah", 1.0, 1.4, "B"), w("right", 1.4, 2.0, "B"),
        ]
        let turns = TurnAssembler().assemble(words)
        #expect(turns == [
            Turn(speaker: "A", text: "one two three four five six"),
            Turn(speaker: "B", text: "yeah right"),
        ])
    }

    @Test func pauseLongerThanPhraseGapSplitsAPhrase() {
        let split = TurnAssembler(phraseGap: 0.7, turnGap: 0.1).assemble([
            w("a", 0.0, 0.5, "A"), w("b", 1.3, 1.8, "A"),   // gap 0.8 > 0.7
        ])
        #expect(split.count == 2)

        let joined = TurnAssembler(phraseGap: 0.7, turnGap: 0.1).assemble([
            w("a", 0.0, 0.5, "A"), w("b", 1.1, 1.6, "A"),   // gap 0.6 <= 0.7
        ])
        #expect(joined == [Turn(speaker: "A", text: "a b")])
    }

    @Test func sameSpeakerPhrasesMergeWithinTurnGap() {
        let one = TurnAssembler().assemble([
            w("a", 0.0, 0.5, "A"), w("b", 2.0, 2.5, "A"),   // phrase gap 1.5: two phrases, one turn
        ])
        #expect(one == [Turn(speaker: "A", text: "a b")])

        let two = TurnAssembler().assemble([
            w("a", 0.0, 0.5, "A"), w("b", 3.0, 3.5, "A"),   // 2.5 > 2.0: two turns
        ])
        #expect(two == [Turn(speaker: "A", text: "a"), Turn(speaker: "A", text: "b")])
    }

    @Test func otherSpeakerBetweenPhrasesBreaksTheTurn() {
        let turns = TurnAssembler().assemble([
            w("a", 0.0, 0.5, "A"), w("x", 1.0, 1.5, "B"), w("b", 2.0, 2.5, "A"),
        ])
        #expect(turns == [
            Turn(speaker: "A", text: "a"), Turn(speaker: "B", text: "x"), Turn(speaker: "A", text: "b"),
        ])
    }

    @Test func emptyInputYieldsNoTurns() {
        #expect(TurnAssembler().assemble([]).isEmpty)
    }

    @Test func spikeInterleavingPatternHasNoSingleWordTurns() {
        // "it's gonna be incredibly useful" with "yeah for sure" spoken over the middle of it.
        let them = ["it's", "gonna", "be", "incredibly", "useful"].enumerated().map { i, t in
            w(t, Double(i) * 0.4, Double(i) * 0.4 + 0.35, "Speaker 1")
        }
        let me = ["yeah", "for", "sure"].enumerated().map { i, t in
            w(t, 0.6 + Double(i) * 0.3, 0.6 + Double(i) * 0.3 + 0.25, "Me")
        }
        let turns = TurnAssembler().assemble(them + me)
        #expect(turns.count == 2)
        #expect(turns.allSatisfy { $0.text.split(separator: " ").count > 1 })
        #expect(turns[0].speaker == "Speaker 1")
        #expect(turns[1].speaker == "Me")
    }

    @Test func phrasesStartingAtTheSameTimeKeepFirstAppearanceOrder() {
        let turns = TurnAssembler().assemble([
            w("b", 0.0, 0.5, "B"), w("a", 0.0, 0.5, "A"),
        ])
        #expect(turns.map(\.speaker) == ["B", "A"])
    }
}
