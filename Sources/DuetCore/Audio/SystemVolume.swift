import CoreAudio
import Foundation

/// The Mac's own volume on one output device (what the volume keys and Control Center change).
public struct SystemVolume: Sendable {
    public let device: AudioObjectID

    public init(device: AudioObjectID) { self.device = device }

    public var isAvailable: Bool { CA.has(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput) }

    /// Slider position, 0...1.
    public var position: Float {
        get { (try? CA.scalar(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, as: Float32.self)) ?? 1 }
        nonmutating set { try? CA.setScalar(device, kAudioDevicePropertyVolumeScalar, Float32(max(0, min(1, newValue))), kAudioObjectPropertyScopeOutput) }
    }

    public var isMuted: Bool {
        get { ((try? CA.scalar(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, as: UInt32.self)) ?? 0) != 0 }
        nonmutating set { try? CA.setScalar(device, kAudioDevicePropertyMute, UInt32(newValue ? 1 : 0), kAudioObjectPropertyScopeOutput) }
    }

    /// The linear gain the device applies now (0 when muted), to give other outputs the same loudness change.
    public var gain: Float {
        if isMuted { return 0 }
        guard let db = try? CA.scalar(device, kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, as: Float32.self) else { return 1 }
        return powf(10, db / 20)
    }

    /// Calls `block` on the main queue whenever the volume or mute changes. Keep the tokens.
    public func observe(_ block: @escaping @Sendable () -> Void) -> [AnyObject] {
        [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].map {
            CA.listen(device, $0, kAudioObjectPropertyScopeOutput, queue: .main, block)
        }
    }
}

/// Notifies about changes to the device list and to the default output.
public enum DeviceEvents {
    public static func observe(_ block: @escaping @Sendable () -> Void) -> [AnyObject] {
        [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice].map {
            CA.listen(CA.system, $0, queue: .main, block)
        }
    }
}
