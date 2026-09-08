import CoreAudio
import Foundation

/// A private aggregate device made of the current default input device (clock
/// master) and a system audio tap (drift compensated). Its input streams are
/// the mic's streams followed by the tap's stream.
public final class AggregateDevice {
    public let deviceID: AudioDeviceID
    public let layout: InputLayout
    public let sampleRate: Double
    public let micName: String

    public init(tap: ProcessTap) throws {
        let mic = try CoreAudio.defaultInputDevice()
        let micUID = try CoreAudio.uid(of: mic)
        let micStreams = try CoreAudio.inputStreamChannelCounts(of: mic)
        micName = CoreAudio.name(of: mic)

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Scribe Recorder",
            kAudioAggregateDeviceUIDKey as String: "com.jacobmarchionda.scribe.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: micUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: micUID,
                    kAudioSubDeviceDriftCompensationKey as String: 0,
                ],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tap.uid,
                    kAudioSubTapDriftCompensationKey as String: 1,
                ],
            ],
        ]

        var id = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw ScribeError.aggregateCreationFailed(status)
        }
        deviceID = id

        do {
            sampleRate = try CoreAudio.nominalSampleRate(of: id)
            let streams = try CoreAudio.inputStreamChannelCounts(of: id)
            layout = Self.makeLayout(aggregateStreams: streams, micStreams: micStreams)
        } catch {
            AudioHardwareDestroyAggregateDevice(id)
            throw error
        }
    }

    /// Sub-device streams come first in an aggregate's stream list, taps last.
    static func makeLayout(aggregateStreams: [Int], micStreams: [Int]) -> InputLayout {
        let micCount = min(micStreams.count, aggregateStreams.count)
        return InputLayout(
            micBuffers: Array(0..<micCount),
            systemBuffers: Array(micCount..<aggregateStreams.count))
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }
}
