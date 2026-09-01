import CoreAudio
import Foundation

/// Enumerates CoreAudio input devices.
///
/// CoreAudio directly rather than `AVCaptureDevice`, for two reasons: the
/// `AudioDeviceID` is the thing `MicCapture` has to set on its audio unit, so
/// going through `AVCaptureDevice` would only mean translating a UID back again;
/// and the input channel count is readable here *before* selecting a device,
/// which pre-empts the zero-channel aggregate-device failure that `MicCapture`
/// otherwise only discovers by throwing.
enum AudioDevices {

    /// Every device that can actually be recorded, in CoreAudio's own order.
    static func inputs() -> [MicDevice] {
        deviceIDs().compactMap { device(for: $0) }
    }

    /// The system default input, or nil when there is none.
    static func defaultInput() -> MicDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != 0 else { return nil }
        return device(for: id)
    }

    /// Restores a persisted choice. Nil when that device is no longer present,
    /// which is the unplugged-interface case the caller has to fall back from.
    static func resolve(uid: String) -> MicDevice? {
        guard !uid.isEmpty else { return nil }
        return inputs().first { $0.uid == uid }
    }

    // MARK: - Change notification

    /// Calls back on the main queue whenever devices are added or removed, so a
    /// picker left open reflects a mic being plugged in.
    ///
    /// Returns a token; pass it to `stopObserving` to unregister.
    static func observeChanges(_ onChange: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        return block
    }

    static func stopObserving(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }

    // MARK: - Property reads

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    /// Builds a device, or nil when it has no input channels and so cannot be
    /// recorded at all.
    private static func device(for id: AudioDeviceID) -> MicDevice? {
        let channels = inputChannels(of: id)
        guard channels > 0 else { return nil }
        guard let uid = string(kAudioDevicePropertyDeviceUID, of: id) else { return nil }
        let name = string(kAudioObjectPropertyName, of: id) ?? "Unknown input"
        return MicDevice(id: id, uid: uid, name: name, channels: channels)
    }

    /// Sums the channels across every buffer in the input stream configuration.
    /// A device with buffers but zero channels is exactly the "reports no usable
    /// input channels" case in `CaptureError.invalidInputFormat`.
    private static func inputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr
        else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        let string = value as String
        return string.isEmpty ? nil : string
    }
}
