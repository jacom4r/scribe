import CoreAudio
import Foundation

/// A Core Audio process tap on the mixed output of every process.
/// Mono, private (not visible to other apps), unmuted (the user still hears audio).
public final class ProcessTap {
    public let objectID: AudioObjectID
    public let uid: String
    public let format: AudioStreamBasicDescription

    public init() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Scribe System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw ScribeError.tapCreationFailed(status)
        }
        objectID = id
        uid = description.uuid.uuidString

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &asbd)
        guard formatStatus == noErr else {
            AudioHardwareDestroyProcessTap(id)
            throw ScribeError.tapCreationFailed(formatStatus)
        }
        format = asbd
    }

    deinit {
        AudioHardwareDestroyProcessTap(objectID)
    }
}
