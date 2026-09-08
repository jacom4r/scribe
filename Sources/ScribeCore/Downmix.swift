import CoreAudio

/// Which buffers in the aggregate device's input `AudioBufferList` carry which
/// source. Buffer `i` corresponds to input stream `i` of the device.
public struct InputLayout: Equatable, Sendable {
    public var micBuffers: [Int]
    public var systemBuffers: [Int]

    public init(micBuffers: [Int], systemBuffers: [Int]) {
        self.micBuffers = micBuffers
        self.systemBuffers = systemBuffers
    }
}

/// Mixes an input buffer list down to interleaved stereo Float32:
/// left = mean of all mic channels, right = mean of all system channels.
///
/// Real-time safe: no allocation, no locks. Writes at most `output.count / 2`
/// frames and returns how many were written. Output frames are fully
/// overwritten, so callers need not zero the buffer.
@discardableResult
func downmix(_ input: UnsafeMutableAudioBufferListPointer,
             frames: Int,
             layout: InputLayout,
             into output: UnsafeMutableBufferPointer<Float>) -> Int {
    let frames = min(frames, output.count / 2)
    guard frames > 0 else { return 0 }

    for f in 0..<frames {
        output[2 * f] = 0
        output[2 * f + 1] = 0
    }
    accumulate(input, buffers: layout.micBuffers, frames: frames, channelOffset: 0, into: output)
    accumulate(input, buffers: layout.systemBuffers, frames: frames, channelOffset: 1, into: output)
    return frames
}

private func accumulate(_ input: UnsafeMutableAudioBufferListPointer,
                        buffers: [Int],
                        frames: Int,
                        channelOffset: Int,
                        into output: UnsafeMutableBufferPointer<Float>) {
    var totalChannels = 0
    for i in buffers where i >= 0 && i < input.count {
        totalChannels += Int(input[i].mNumberChannels)
    }
    guard totalChannels > 0 else { return }
    let scale = 1 / Float(totalChannels)

    for i in buffers where i >= 0 && i < input.count {
        let buffer = input[i]
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0, let data = buffer.mData else { continue }
        let available = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
        let samples = data.assumingMemoryBound(to: Float.self)
        let n = min(frames, available)
        for f in 0..<n {
            var sum: Float = 0
            for c in 0..<channels {
                sum += samples[f * channels + c]
            }
            output[2 * f + channelOffset] += sum * scale
        }
    }
}
