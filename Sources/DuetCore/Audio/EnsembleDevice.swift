import CoreAudio
import Foundation

/// Ensemble's sound device (Driver/EnsembleDevice.c), when installed. While this Mac shares its sound,
/// apps play to it and Ensemble reads their sound from its hidden capture twin; the device reports the
/// delay as its latency, so video players hold the picture back to match. Both exist only while Ensemble
/// asks for them, and go when Ensemble exits. Without the driver, every call here does nothing and this
/// Mac cannot share. The app carries the driver and installs it on request.
public enum EnsembleDevice {
    static let uid = "com.lacrearthur.duet.device"
    static let captureUID = "com.lacrearthur.duet.capture"
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

    /// True when the app carries a driver that is not the one installed: none, or another version.
    public static var needsInstall: Bool {
        guard let bundled = Bundle.main.url(forResource: "EnsembleDevice", withExtension: "driver") else { return false }
        return version(installed) != version(bundled)
    }

    /// Copies the app's driver into the system (macOS asks for an administrator password), then restarts
    /// Core Audio so it loads it: every sound stops for a moment. False if the user cancels or it fails.
    public static func install() -> Bool {
        guard let bundled = Bundle.main.url(forResource: "EnsembleDevice", withExtension: "driver") else { return false }
        let literal = { (path: String) in "quoted form of \"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let source = """
            do shell script "/bin/rm -rf " & \(literal(installed.path)) & " && /usr/bin/ditto --noqtn " & \(literal(bundled.path)) & " " & \(literal(installed.path)) & " && /usr/bin/killall coreaudiod" with administrator privileges
            """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    private static let installed = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/EnsembleDevice.driver")

    private static func version(_ driver: URL) -> String? {
        NSDictionary(contentsOf: driver.appending(path: "Contents/Info.plist"))?["CFBundleVersion"] as? String
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
