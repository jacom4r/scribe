import Testing

@testable import ScribeCore

/// Feeds events in order and returns the effects of the last one only;
/// earlier events just set up state.
private func run(
    _ d: inout MeetingDetector, _ events: MeetingDetector.Event...
) -> [MeetingDetector.Effect] {
    var last: [MeetingDetector.Effect] = []
    for event in events { last = d.handle(event) }
    return last
}

/// Feeds events in order and returns the effects of every event.
private func runAll(
    _ d: inout MeetingDetector, _ events: MeetingDetector.Event...
) -> [MeetingDetector.Effect] {
    events.flatMap { d.handle($0) }
}

/// A recording armed by Teams whose mic has just gone off: countdown running.
private func countingDown() -> MeetingDetector {
    var d = MeetingDetector()
    _ = run(&d, .teamsMic(true), .startPressed, .recordingStarted, .teamsMic(false))
    return d
}

@Suite struct MeetingDetectorTests {
    @Test func micOnWhileIdlePostsPrompt() {
        var d = MeetingDetector()
        #expect(run(&d, .teamsMic(false), .teamsMic(true)) == [.postStartPrompt])
    }

    @Test func repeatedMicOnPostsOnce() {
        var d = MeetingDetector()
        #expect(run(&d, .teamsMic(false), .teamsMic(true), .teamsMic(true)) == [])
    }

    @Test func ignoringPromptNeverRecords() {
        var d = MeetingDetector()
        let all = runAll(&d, .teamsMic(false), .teamsMic(true), .teamsMic(false))
        #expect(all == [.postStartPrompt, .removeStartPrompt])
        #expect(!all.contains(.startRecording))
    }

    @Test func startPressedStartsRecording() {
        var d = MeetingDetector()
        #expect(run(&d, .teamsMic(true), .startPressed) == [.startRecording])
    }

    @Test func startPressedWhileMicOffIsIgnored() {
        var d = MeetingDetector()
        #expect(run(&d, .teamsMic(true), .teamsMic(false), .startPressed) == [])
    }

    @Test func startPressedBeforeFirstReadingWaitsForMicOn() {
        var d = MeetingDetector()
        #expect(run(&d, .startPressed) == [])
        #expect(run(&d, .teamsMic(true)) == [.startRecording])
    }

    @Test func startPressedBeforeFirstReadingDroppedIfMicOff() {
        var d = MeetingDetector()
        #expect(run(&d, .startPressed, .teamsMic(false)) == [])
        #expect(run(&d, .teamsMic(true)) == [.postStartPrompt])
    }

    @Test func startPressedWhileRecordingIsIgnored() {
        var d = MeetingDetector()
        #expect(run(&d, .teamsMic(true), .recordingStarted, .startPressed) == [])
    }

    @Test func noPromptWhileRecording() {
        var d = MeetingDetector()
        #expect(run(&d, .teamsMic(false), .recordingStarted, .teamsMic(true)) == [])
    }

    @Test func manualStartRemovesShowingPrompt() {
        var d = MeetingDetector()
        #expect(run(&d, .teamsMic(true), .recordingStarted) == [.removeStartPrompt])
    }

    @Test func micOffWhileArmedBeginsCountdown() {
        var d = MeetingDetector()
        #expect(
            run(&d, .teamsMic(true), .startPressed, .recordingStarted, .teamsMic(false))
                == [.beginCountdown])
    }

    @Test func manualRecordingArmsWhenTeamsJoinsLater() {
        var d = MeetingDetector()
        #expect(
            run(&d, .teamsMic(false), .recordingStarted, .teamsMic(true), .teamsMic(false))
                == [.beginCountdown])
    }

    @Test func recordingWithoutTeamsNeverAutoStops() {
        var d = MeetingDetector()
        let all = runAll(&d, .teamsMic(false), .recordingStarted, .countdownElapsed)
        #expect(all == [])
        #expect(!all.contains(.beginCountdown))
    }

    @Test func countdownElapsedStopsRecording() {
        var d = countingDown()
        #expect(run(&d, .countdownElapsed) == [.endCountdown, .stopRecording])
    }

    @Test func micBackDuringCountdownCancelsIt() {
        var d = countingDown()
        #expect(run(&d, .teamsMic(true)) == [.endCountdown])
        #expect(run(&d, .teamsMic(false)) == [.beginCountdown])
    }

    @Test func continueCancelsAndDisarms() {
        var d = countingDown()
        #expect(run(&d, .continuePressed) == [.endCountdown])
        #expect(run(&d, .countdownElapsed) == [])
    }

    @Test func continueThenTeamsAgainRearms() {
        var d = countingDown()
        #expect(
            run(&d, .continuePressed, .teamsMic(true), .teamsMic(false)) == [.beginCountdown])
    }

    @Test func manualStopDuringCountdownCancelsIt() {
        var d = countingDown()
        #expect(run(&d, .recordingStopped) == [.endCountdown])
        #expect(run(&d, .teamsMic(true)) == [.postStartPrompt])
    }

    @Test func failedStartLeavesNothingArmed() {
        var d = MeetingDetector()
        #expect(run(&d, .teamsMic(true), .startPressed, .teamsMic(false)) == [])
    }

    @Test func staleCountdownElapsedIsIgnored() {
        var d = MeetingDetector()
        #expect(
            run(&d, .teamsMic(true), .startPressed, .recordingStarted, .countdownElapsed) == [])
    }
}
