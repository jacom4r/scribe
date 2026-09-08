import CoreAudio
import Testing
@testable import ScribeCore

/// Owns a heap AudioBufferList built from interleaved sample arrays.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer

    init(_ buffers: [(channels: Int, interleaved: [Float])]) {
        list = AudioBufferList.allocate(maximumBuffers: max(buffers.count, 1))
        for (i, b) in buffers.enumerated() {
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: b.interleaved.count)
            ptr.initialize(from: b.interleaved, count: b.interleaved.count)
            list[i] = AudioBuffer(
                mNumberChannels: UInt32(b.channels),
                mDataByteSize: UInt32(b.interleaved.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(ptr))
        }
        list.count = buffers.count
    }

    deinit {
        for b in list { b.mData?.assumingMemoryBound(to: Float.self).deallocate() }
        free(list.unsafeMutablePointer)
    }
}

@Suite struct DownmixTests {
    private func run(_ input: TestBufferList, frames: Int, layout: InputLayout, capacity: Int? = nil) -> (written: Int, out: [Float]) {
        let cap = capacity ?? frames
        let out = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap * 2)
        defer { out.deallocate() }
        out.initialize(repeating: 99)
        let written = downmix(input.list, frames: frames, layout: layout, into: out)
        return (written, Array(out))
    }

    @Test func stereoMicAndMonoTap() {
        // 2 frames. Mic L/R: (0.2, 0.4), (1.0, 0.0). Tap: 0.8, -0.5
        let input = TestBufferList([
            (channels: 2, interleaved: [0.2, 0.4, 1.0, 0.0]),
            (channels: 1, interleaved: [0.8, -0.5]),
        ])
        let layout = InputLayout(micBuffers: [0], systemBuffers: [1])
        let r = run(input, frames: 2, layout: layout)

        #expect(r.written == 2)
        #expect(abs(r.out[0] - 0.3) < 1e-6)   // frame 0 left  = mean(0.2, 0.4)
        #expect(abs(r.out[1] - 0.8) < 1e-6)   // frame 0 right = tap
        #expect(abs(r.out[2] - 0.5) < 1e-6)   // frame 1 left  = mean(1.0, 0.0)
        #expect(abs(r.out[3] - -0.5) < 1e-6)  // frame 1 right
    }

    @Test func micSplitAcrossTwoMonoStreams() {
        let input = TestBufferList([
            (channels: 1, interleaved: [0.2, 0.6]),
            (channels: 1, interleaved: [0.4, 0.2]),
            (channels: 1, interleaved: [1.0, 1.0]),
        ])
        let layout = InputLayout(micBuffers: [0, 1], systemBuffers: [2])
        let r = run(input, frames: 2, layout: layout)

        #expect(abs(r.out[0] - 0.3) < 1e-6)
        #expect(abs(r.out[2] - 0.4) < 1e-6)
        #expect(abs(r.out[1] - 1.0) < 1e-6)
    }

    @Test func missingSystemBuffersGiveSilentRight() {
        let input = TestBufferList([(channels: 1, interleaved: [0.5, 0.5])])
        let layout = InputLayout(micBuffers: [0], systemBuffers: [])
        let r = run(input, frames: 2, layout: layout)

        #expect(r.out[0] == 0.5)
        #expect(r.out[1] == 0)
        #expect(r.out[3] == 0)
    }

    @Test func clampsToOutputCapacity() {
        let input = TestBufferList([
            (channels: 1, interleaved: [0.1, 0.2, 0.3, 0.4]),
            (channels: 1, interleaved: [0.1, 0.2, 0.3, 0.4]),
        ])
        let layout = InputLayout(micBuffers: [0], systemBuffers: [1])
        let r = run(input, frames: 4, layout: layout, capacity: 2)

        #expect(r.written == 2)
        #expect(abs(r.out[2] - 0.2) < 1e-6)
    }

    @Test func ignoresBufferIndicesOutOfRange() {
        let input = TestBufferList([(channels: 1, interleaved: [0.5])])
        let layout = InputLayout(micBuffers: [0], systemBuffers: [7])
        let r = run(input, frames: 1, layout: layout)

        #expect(r.out[0] == 0.5)
        #expect(r.out[1] == 0)
    }
}
