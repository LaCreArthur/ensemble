import CoreAudio
import Foundation

/// Ensemble's sound device (Driver/EnsembleDevice.c), when installed. While this Mac shares its sound,
/// apps play to it and Ensemble captures them as from any output; the device reports the delay as its
/// latency, so video players hold the picture back to match. It exists only while Ensemble asks for it,
/// and goes when Ensemble exits. Without the driver, every call here does nothing.
public enum EnsembleDevice {
    static let uid = "com.lacrearthur.duet.device"
    /// On the plug-in: the device's latency in frames, -1 for no device (a property list number).
    private static let attach: AudioObjectPropertySelector = 0x656E_6C64   // 'enld'
    private static let sampleRate = 48_000.0

    /// The device, while it exists.
    public static var id: AudioObjectID? { translate(kAudioHardwarePropertyTranslateUIDToDevice, uid) }

    /// True while the device is the Mac's sound output.
    public static var isSystemOutput: Bool {
        guard let id else { return false }
        return (try? CA.scalar(CA.system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)) == id
    }

    /// Makes the device the Mac's sound output.
    public static func makeSystemOutput() {
        guard let id else { return }
        try? CA.setScalar(CA.system, kAudioHardwarePropertyDefaultOutputDevice, id)
    }

    /// Makes the device exist with this latency (seconds), or removes it (nil). The device appears or goes
    /// a moment later, announced as a device list change.
    public static func setLatency(_ seconds: Double?) {
        guard let plugIn = translate(kAudioHardwarePropertyTranslateBundleIDToPlugIn, uid) else { return }
        let frames = seconds.map { Int(($0 * sampleRate).rounded()) } ?? -1
        var address = CA.address(attach)
        var current: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList>.size)
        if AudioObjectGetPropertyData(plugIn, &address, 0, nil, &size, &current) == noErr,
           (current?.takeRetainedValue() as? NSNumber)?.intValue == frames { return }
        var value: CFPropertyList = NSNumber(value: frames)
        _ = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(plugIn, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0) }
    }

    private static func translate(_ selector: AudioObjectPropertySelector, _ key: String) -> AudioObjectID? {
        var address = CA.address(selector)
        var qualifier = key as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) {
            AudioObjectGetPropertyData(CA.system, &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }
}
