import CoreAudio
import Foundation

/// Calls `onChange` on the main queue whenever a system default device
/// changes (headset unplugged, AirPods connected, ...). Which default is
/// watched is set by `selector`; see `defaultInput` and `defaultOutput`.
final class DefaultDeviceWatcher {
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init(selector: AudioObjectPropertySelector, onChange: @escaping @Sendable () -> Void) {
        address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        block = { _, _ in onChange() }
    }

    static func defaultInput(onChange: @escaping @Sendable () -> Void) -> DefaultDeviceWatcher {
        DefaultDeviceWatcher(selector: kAudioHardwarePropertyDefaultInputDevice, onChange: onChange)
    }

    static func defaultOutput(onChange: @escaping @Sendable () -> Void) -> DefaultDeviceWatcher {
        DefaultDeviceWatcher(selector: kAudioHardwarePropertyDefaultOutputDevice, onChange: onChange)
    }

    func start() throws {
        guard !installed else { return }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        guard status == noErr else { throw ScribeError.captureStartFailed(status) }
        installed = true
    }

    func stop() {
        guard installed else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        installed = false
    }

    deinit {
        stop()
    }
}
