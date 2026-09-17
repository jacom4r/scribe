import Foundation
import Testing
@testable import ScribeCore

@Suite struct TranscriptRendererTests {
    @Test func rendersHeaderAndTurns() {
        let turns = [
            Turn(speaker: "Me", text: "Hi both, thanks for joining."),
            Turn(speaker: "Speaker 1", text: "Sure. Did you see the note?"),
            Turn(speaker: "Me", text: "I did, yes."),
        ]
        let md = TranscriptRenderer().render(
            turns: turns, recordingName: "2026-09-16 14-30 Recording.wav", duration: 2832)
        #expect(md == """
            # Meeting 2026-09-16 14:30

            Recording: 2026-09-16 14-30 Recording.wav
            Duration: 47:12
            Speakers: Me, Speaker 1

            **Me**
            Hi both, thanks for joining.

            **Speaker 1**
            Sure. Did you see the note?

            **Me**
            I did, yes.

            """)
    }

    @Test func noTurnsRendersSpeakersNone() {
        let md = TranscriptRenderer().render(
            turns: [], recordingName: "2026-09-16 14-30 Recording.wav", duration: 5)
        #expect(md == """
            # Meeting 2026-09-16 14:30

            Recording: 2026-09-16 14-30 Recording.wav
            Duration: 0:05
            Speakers: none

            """)
    }

    @Test func speakersListedInOrderOfFirstTurn() {
        let turns = [
            Turn(speaker: "Speaker 2", text: "a"), Turn(speaker: "Me", text: "b"),
            Turn(speaker: "Speaker 2", text: "c"), Turn(speaker: "Speaker 1", text: "d"),
        ]
        let md = TranscriptRenderer().render(turns: turns, recordingName: "x.wav", duration: 0)
        #expect(md.contains("Speakers: Speaker 2, Me, Speaker 1\n"))
    }

    @Test func durationFormatting() {
        #expect(TranscriptRenderer.formatDuration(5) == "0:05")
        #expect(TranscriptRenderer.formatDuration(62) == "1:02")
        #expect(TranscriptRenderer.formatDuration(3723) == "1:02:03")
        #expect(TranscriptRenderer.formatDuration(3599.9) == "59:59")
    }

    @Test func titleFallsBackToBareNameWithoutDatePrefix() {
        #expect(TranscriptRenderer.title(for: "2026-09-16 14-30 Recording (2).wav") == "Meeting 2026-09-16 14:30")
        #expect(TranscriptRenderer.title(for: "standup.wav") == "Meeting standup")
    }
}
