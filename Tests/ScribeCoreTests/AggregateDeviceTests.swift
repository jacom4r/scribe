import Testing
@testable import ScribeCore

@Suite struct AggregateDeviceTests {
    @Test func stereoMicThenMonoTap() {
        let layout = AggregateDevice.makeLayout(aggregateStreams: [2, 1], micStreams: [2])
        #expect(layout == InputLayout(micBuffers: [0], systemBuffers: [1]))
    }

    @Test func multiStreamMic() {
        let layout = AggregateDevice.makeLayout(aggregateStreams: [1, 1, 1], micStreams: [1, 1])
        #expect(layout == InputLayout(micBuffers: [0, 1], systemBuffers: [2]))
    }

    @Test func tapMissingGivesNoSystemBuffers() {
        let layout = AggregateDevice.makeLayout(aggregateStreams: [1], micStreams: [1])
        #expect(layout == InputLayout(micBuffers: [0], systemBuffers: []))
    }

    @Test func fewerAggregateStreamsThanMicStreamsDoesNotCrash() {
        let layout = AggregateDevice.makeLayout(aggregateStreams: [1], micStreams: [1, 1])
        #expect(layout == InputLayout(micBuffers: [0], systemBuffers: []))
    }
}
