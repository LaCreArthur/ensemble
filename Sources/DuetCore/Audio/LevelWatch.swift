import CoreAudio
import Foundation

/// Tells when a sound starts on this Mac: after at least `silence` seconds below `floor`, sound above
/// it that lasts `minimum` seconds (an alert is shorter). Short dips inside a sound do not restart the
/// count. A sound already playing when the watch begins never counts until it stops, so a sound that
/// kept playing after this Mac stopped sharing does not take sharing back.
public struct SoundStart {
    /// About -100 dBFS: an app that is paused but keeps its output open plays exact zeros.
    public static let floor: Float = 1e-5
    public let rate: Double
    public let minimum: Double
    public let silence: Double
    private var quiet = 0
    private var loud = 0
    private var armed = false

    public init(rate: Double, minimum: Double = 2, silence: Double = 0.25) {
        self.rate = rate
        self.minimum = minimum
        self.silence = silence
    }

    /// Takes one cycle's peak level over `frames` frames; true once per sound start.
    public mutating func feed(peak: Float, frames: Int) -> Bool {
        if peak < Self.floor {
            quiet += frames
            if Double(quiet) >= silence * rate {
                armed = true
                loud = 0
            }
            return false
        }
        quiet = 0
        guard armed else { return false }
        loud += frames
        guard Double(loud) >= minimum * rate else { return false }
        armed = false
        loud = 0
        return true
    }
}

/// Listens to the sound of every process but the excluded ones, without silencing it (unlike the
/// capture), on a private aggregate of `device`, and calls `onStart` on the main queue when a sound starts.
public final class LevelWatch: @unchecked Sendable {
    private let excluded: [pid_t]
    private let device: OutputDevice
    private let onStart: @Sendable () -> Void
    private var detector: SoundStart
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    public init(excluding pids: [pid_t], device: OutputDevice, minimum: Double = 2, onStart: @escaping @Sendable () -> Void) {
        excluded = pids
        self.device = device
        self.onStart = onStart
        detector = SoundStart(rate: device.nominalSampleRate, minimum: minimum)
    }

    deinit { stop() }

    public func start() throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: try excluded.map(processObject(for:)))
        tap.uuid = UUID()
        tap.name = "Ensemble watch"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create watch tap")
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ensemble watch",
            kAudioAggregateDeviceUIDKey: "duet.watch.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create watch device")
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [unowned self] _, input, _, output, _ in
                self.listen(input, output: output)
            }, "create watch IO proc")
            try check(AudioDeviceStart(aggregateID, procID), "start watch")
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Whether this process's running audio may let the Mac sleep (a watch or a capture may; playing the
    /// other Mac's sound may not, as it is the only sound here).
    public static func allowSleep(_ allowed: Bool) {
        try? CA.setScalar(CA.system, kAudioHardwarePropertySleepingIsAllowed, UInt32(allowed ? 1 : 0))
    }

    // MARK: IO thread

    private func listen(_ input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var peak: Float = 0
        var frames = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            frames = max(frames, count / max(1, Int(buffer.mNumberChannels)))
            for i in 0..<count { peak = max(peak, abs(data[i])) }
        }
        if frames > 0, detector.feed(peak: peak, frames: frames) {
            let onStart = onStart
            DispatchQueue.main.async { onStart() }
        }
    }
}
