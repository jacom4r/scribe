import CoreAudio

/// A preallocated interleaved stereo Float32 buffer plus a one-buffer
/// `AudioBufferList` pointing at it. Allocated once, reused on the audio thread.
public final class StereoBuffer {
    public let capacityFrames: Int
    public let samples: UnsafeMutableBufferPointer<Float>
    private let list: UnsafeMutablePointer<AudioBufferList>

    public init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
        samples = .allocate(capacity: capacityFrames * 2)
        samples.initialize(repeating: 0)
        list = .allocate(capacity: 1)
        list.initialize(to: AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: 0,
                mData: UnsafeMutableRawPointer(samples.baseAddress))))
    }

    /// The list, sized to `frames` frames. Real-time safe.
    public func bufferList(frames: Int) -> UnsafePointer<AudioBufferList> {
        let frames = min(max(frames, 0), capacityFrames)
        list.pointee.mBuffers.mDataByteSize = UInt32(frames * 2 * MemoryLayout<Float>.size)
        return UnsafePointer(list)
    }

    deinit {
        samples.deallocate()
        list.deallocate()
    }
}
