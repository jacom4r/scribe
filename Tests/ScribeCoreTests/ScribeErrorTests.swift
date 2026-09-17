import Testing
@testable import ScribeCore

@Suite struct ScribeErrorTests {
    @Test func everyCaseHasAUserMessage() {
        let cases: [ScribeError] = [
            .permissionDenied, .tapCreationFailed(-1), .aggregateCreationFailed(-2),
            .captureStartFailed(-3), .noInputDevice, .writeFailed(-4),
            .inputDeviceChanged, .notRecording, .alreadyRecording,
            .modelsUnavailable("offline"), .transcriptionFailed("boom"),
        ]
        for c in cases {
            #expect(!c.userMessage.isEmpty)
        }
        #expect(ScribeError.writeFailed(-4).userMessage.contains("-4"))
    }

    @Test func transcriptionMessagesCarryTheDetail() {
        #expect(ScribeError.modelsUnavailable("offline").userMessage == "Transcription models couldn't be loaded (offline).")
        #expect(ScribeError.transcriptionFailed("boom").userMessage == "Transcription failed (boom).")
    }
}
