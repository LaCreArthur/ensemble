import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let what: String
    public var description: String { "\(what) failed (\(status))" }
}

@discardableResult
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws -> OSStatus {
    if status != noErr { throw CoreAudioError(status: status, what: what()) }
    return status
}

/// Thin typed access to AudioObject properties.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope)
        return AudioObjectHasProperty(id, &addr)
    }

    static func scalar<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                           _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                                           as type: T.Type = T.self) throws -> T {
        var addr = address(selector, scope, element)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, value), "get \(fourCC(selector)) on \(id)")
        return value.pointee
    }

    static func setScalar<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T,
                                              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                              _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws {
        var addr = address(selector, scope, element)
        var v = value
        try check(AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v), "set \(fourCC(selector)) on \(id)")
    }

    static func array<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                          as type: T.Type = T.self) throws -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "size \(fourCC(selector)) on \(id)")
        let count = Int(size) / MemoryLayout<T>.stride
        if count == 0 { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer), "get \(fourCC(selector)) on \(id)")
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) },
                  "get \(fourCC(selector)) on \(id)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    /// Number of channels in the given scope, summed over all streams.
    static func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Number of buffers (streams) a device uses in the given scope.
    /// Frames between handing a frame to an output device and hearing it, as the device reports.
    static func outputLatencyFrames(_ id: AudioObjectID) -> UInt32 {
        let device = (try? scalar(id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, as: UInt32.self)) ?? 0
        let streams = (try? array(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, as: AudioObjectID.self)) ?? []
        return device + (streams.first.flatMap { try? scalar($0, kAudioStreamPropertyLatency, as: UInt32.self) } ?? 0)
    }

    static func bufferCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? String(v)
    }

    /// Adds a listener block; returns a token that removes it.
    static func listen(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       queue: DispatchQueue, _ block: @escaping () -> Void) -> ListenerToken {
        var addr = address(selector, scope)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in block() }
        AudioObjectAddPropertyListenerBlock(id, &addr, queue, listener)
        return ListenerToken(id: id, address: addr, queue: queue, block: listener)
    }

    final class ListenerToken {
        let id: AudioObjectID
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
        init(id: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
            self.id = id; self.address = address; self.queue = queue; self.block = block
        }
        deinit { AudioObjectRemovePropertyListenerBlock(id, &address, queue, block) }
    }
}

/// An output-capable CoreAudio device.
public struct OutputDevice: Hashable, Identifiable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: UInt32

    /// Bluetooth: headphones (private listening) unless the user ticks it in the menu as a speaker.
    public var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The Mac's own speakers.
    public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    public static func all() -> [OutputDevice] {
        let ids = (try? CA.array(CA.system, kAudioHardwarePropertyDevices, as: AudioObjectID.self)) ?? []
        return ids.compactMap { OutputDevice(id: $0) }
    }

    public static func allDeviceIDs() -> [AudioObjectID] {
        (try? CA.array(CA.system, kAudioHardwarePropertyDevices, as: AudioObjectID.self)) ?? []
    }

    public static func name(of id: AudioObjectID) -> String {
        (try? CA.string(id, kAudioObjectPropertyName)) ?? ""
    }

    public static func defaultOutput() -> OutputDevice? {
        guard let id = try? CA.scalar(CA.system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self) else { return nil }
        return OutputDevice(id: id)
    }

    public static func setDefaultOutput(_ device: OutputDevice) throws {
        try CA.setScalar(CA.system, kAudioHardwarePropertyDefaultOutputDevice, device.id)
    }

    /// A device not read from the system, so that the lead and lag arithmetic can be tested.
    init(id: AudioObjectID, uid: String, name: String, transport: UInt32) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport
    }

    init?(id: AudioObjectID) {
        guard CA.channelCount(id, kAudioObjectPropertyScopeOutput) > 0,
              let uid = try? CA.string(id, kAudioDevicePropertyDeviceUID),
              let name = try? CA.string(id, kAudioObjectPropertyName) else { return nil }
        let transport = (try? CA.scalar(id, kAudioDevicePropertyTransportType, as: UInt32.self)) ?? 0
        // Aggregate and virtual devices (ours included) are never a speaker choice.
        if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual { return nil }
        if (try? CA.scalar(id, kAudioDevicePropertyIsHidden, as: UInt32.self)) == 1 { return nil }
        self.id = id; self.uid = uid; self.name = name; self.transport = transport
    }

    public var nominalSampleRate: Double {
        (try? CA.scalar(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 48_000
    }

    /// Frames between the moment a frame is handed to the device and the moment it is heard.
    public var outputLatencyFrames: UInt32 { CA.outputLatencyFrames(id) }

    /// Seconds between handing a frame to the device and hearing it, as the device reports.
    public var outputLatency: Double { Double(outputLatencyFrames) / nominalSampleRate }

    /// Frames the device asks for in each cycle.
    public var bufferFrames: UInt32 { (try? CA.scalar(id, kAudioDevicePropertyBufferFrameSize, as: UInt32.self)) ?? 512 }
}

/// The Mac's built-in microphone, if it has one.
public func builtInMicrophone() -> AudioObjectID? {
    OutputDevice.allDeviceIDs().first { id in
        CA.channelCount(id, kAudioObjectPropertyScopeInput) > 0
            && (try? CA.scalar(id, kAudioDevicePropertyTransportType, as: UInt32.self)) == kAudioDeviceTransportTypeBuiltIn
    }
}

/// The CoreAudio process object for a PID (needed to include or exclude a process from a tap).
func processObject(for pid: pid_t) throws -> AudioObjectID {
    var addr = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var p = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(CA.system, &addr, UInt32(MemoryLayout<pid_t>.size), &p, &size, &object),
              "translate pid \(pid)")
    if object == kAudioObjectUnknown { throw CoreAudioError(status: -1, what: "no audio process object for pid \(pid)") }
    return object
}
