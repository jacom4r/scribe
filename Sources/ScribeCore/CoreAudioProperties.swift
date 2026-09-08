import CoreAudio
import Foundation

/// Typed wrappers around the handful of Core Audio properties Scribe reads.
enum CoreAudio {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInputDevice() throws -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { throw ScribeError.noInputDevice }
        return id
    }

    static func uid(of object: AudioObjectID) throws -> String {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { throw ScribeError.noInputDevice }
        return value.takeRetainedValue() as String
    }

    static func name(of object: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { return "Unknown" }
        return value.takeRetainedValue() as String
    }

    static func nominalSampleRate(of device: AudioDeviceID) throws -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { throw ScribeError.aggregateCreationFailed(status) }
        return rate
    }

    /// Channel count of each input stream of `device`, in stream order.
    static func inputStreamChannelCounts(of device: AudioDeviceID) throws -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { throw ScribeError.aggregateCreationFailed(status) }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw)
        guard status == noErr else { throw ScribeError.aggregateCreationFailed(status) }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
