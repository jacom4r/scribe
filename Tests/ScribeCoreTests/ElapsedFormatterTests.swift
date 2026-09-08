import Testing

@testable import ScribeCore

@Suite struct ElapsedFormatterTests {
    @Test func formatsMinutesAndSeconds() {
        #expect(formatElapsed(0) == "0:00")
        #expect(formatElapsed(5.9) == "0:05")
        #expect(formatElapsed(65) == "1:05")
        #expect(formatElapsed(754) == "12:34")
    }

    @Test func formatsHours() {
        #expect(formatElapsed(3600) == "1:00:00")
        #expect(formatElapsed(3725) == "1:02:05")
    }

    @Test func clampsNegative() {
        #expect(formatElapsed(-3) == "0:00")
    }
}
