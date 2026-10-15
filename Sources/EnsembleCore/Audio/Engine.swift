import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Plays one stereo stream on one or more local output devices, all heard together. The stream is
/// either the sound this Mac's apps play to Ensemble's sound device, played after a fixed delay that
/// gives the other Mac time to receive it, or the sound the other Mac sends. The
/// stream's frames go to `ring`, and `anchor` tells when each frame is heard here.
///
/// Timeline: stream frame X is written to `ring` at index X and the main output plays it D frames
/// later. `anchor` holds X and the host time at which frame X is heard on the main output. Every
/// other output runs on its own device and clock, as the other Mac does: each cycle it plays the
/// frame the main output plays at the moment this output is heard (its reported latency plus `lag`),
/// resampled to its own rate. A combined (aggregate) device would delay its fastest devices to match
/// the slowest one's reported latency, so a slow output, such as a Bluetooth speaker, would delay
/// the main output by an amount the engine cannot see.
public final class Engine: @unchecked Sendable {
    public enum Input: Sendable {
        /// What apps play to Ensemble's sound device, read back from its hidden capture twin.
        case loopback
        /// The other Mac's stream.
        case network(StreamReceiver)
    }

    /// Stream frame `frame` is heard on the main output at host time `time` (seconds).
    public struct Anchor: BitwiseCopyable, Sendable {
        public let frame: Int
        public let time: Double
    }

    /// One local output device and its own settings.
    public final class Output: @unchecked Sendable {
        public let device: OutputDevice
        /// Linear gain for this output only.
        public let gain = AtomicFloat(1)
        /// Seconds this output is heard after the latency its device reports (for example a screen's
        /// own processing, or a Bluetooth speaker that reports less than it takes). Not for the main output.
        public let lag = AtomicFloat(0)
        /// Output frames played as silence because the stream was not there yet: the delay is too short for it.
        public let missed = Atomic<Int>(0)
        // Set at start: its own IO proc, playback and one cycle of its sound (every output but the main).
        fileprivate var procID: AudioDeviceIOProcID?
        fileprivate var playhead: Playhead?
        fileprivate var latency = 0.0
        fileprivate var sound: UnsafeMutablePointer<Float>?
        fileprivate var lastGain: Float = 1

        public init(device: OutputDevice) { self.device = device }
        deinit { sound?.deallocate() }
    }

    /// outputs[0] is the main output: its clock drives the engine and `anchor` refers to it. The
    /// main output's latency is the engine's latency; the others follow it on their own devices.
    public let outputs: [Output]
    /// The outputs but the main one play only while this is true; the main output plays from start to stop.
    public private(set) var othersRunning = false
    public let sampleRate: Double
    public let delayFrames: Int
    public let ring: FrameRing
    public let anchor = SeqLock<Anchor?>(nil)
    /// Linear gain on the stream, before every output of this Mac (and the network).
    public let mainGain = AtomicFloat(1)
    /// Frames from the output callback to the ear on the main output, as reported by CoreAudio.
    public private(set) var outputLatencyFrames: UInt32 = 0
    /// Extra correction (seconds) for a main output that reports its latency wrongly.
    public let latencyTrim = AtomicFloat(0)
    /// Loudest captured sample (linear) since the app last set it to 0: shows whether the capture hears the apps.
    public let capturePeak = AtomicFloat(0)

    private let receiver: StreamReceiver?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // Main IO thread only, after start.
    private var framesProcessed: Int = 0
    private var lastMainGain: Float = 1
    /// One cycle of the stream, interleaved stereo.
    private let scratch: UnsafeMutablePointer<Float>
    private static let maxFrames = 16_384
    /// Frames per cycle of the capture and the main output. Each frame of it delays the sound twice (in,
    /// then out); at 32 frames the timing wandered and Core Audio reported overloads (2026-10-15).
    static let cycleFrames: UInt32 = 128
    /// Seconds from an app handing its sound to Ensemble's device to that sound entering the timeline, as
    /// `ensemble-lab device-path` measures it (8.5 ms on a MacBook Pro, the same with apps playing 128 or 512
    /// frames per cycle; a process tap took 69 ms). Part of the latency Ensemble's sound device reports.
    public static let capturePath = 0.0085

    private let pendingClick = Atomic<Int>(-1)
    private let click: [Float]

    public init(input: Input, outputs: [OutputDevice], delaySeconds: Double, sourceRate: Double = 0) {
        precondition(!outputs.isEmpty)
        if case .network(let receiver) = input { self.receiver = receiver } else { receiver = nil }
        self.outputs = outputs.map(Output.init)
        sampleRate = outputs[0].nominalSampleRate
        receiver?.prepare(outputRate: sampleRate, sourceRate: sourceRate > 0 ? sourceRate : sampleRate)
        scratch = .allocate(capacity: Self.maxFrames * 2)
        delayFrames = Int((delaySeconds * sampleRate).rounded())
        ring = FrameRing(capacityFrames: Int(sampleRate * 4) + delayFrames)
        click = AcousticProbe.clickWaveform(sampleRate: sampleRate).map { $0 * 0.3 }
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    public func start(othersRunning: Bool = true) throws {
        // A capture runs all the time while this Mac shares and must not keep it awake: the apps it
        // captures do, while they play. Playing the other Mac's stream is the only sound here, so it does.
        try? CA.setScalar(CA.system, kAudioHardwarePropertySleepingIsAllowed, UInt32(receiver == nil ? 1 : 0))
        let main = outputs[0].device
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ensemble",
            kAudioAggregateDeviceUIDKey: "ensemble.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: main.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: main.uid]]
                + (receiver == nil ? [[kAudioSubDeviceUIDKey: EnsembleDevice.captureUID, kAudioSubDeviceDriftCompensationKey: 1]] : []),
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create aggregate device")
            try? CA.setScalar(aggregateID, kAudioDevicePropertyBufferFrameSize, Self.cycleFrames)
            outputLatencyFrames = CA.outputLatencyFrames(aggregateID)
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [unowned self] _, input, _, output, outputTime in
                self.render(input: input, output: output, outputTime: outputTime)
            }, "create IO proc")
            try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
            for output in outputs.dropFirst() {
                let rate = output.device.nominalSampleRate
                output.playhead = Playhead(ratio: sampleRate / rate)
                output.sound = .allocate(capacity: Self.maxFrames * 2)
                try check(AudioDeviceCreateIOProcIDWithBlock(&output.procID, output.device.id, nil) { [unowned self, unowned output] _, _, _, buffers, outputTime in
                    self.follow(output, rate: rate, output: buffers, outputTime: outputTime)
                }, "create IO proc for \(output.device.name)")
            }
            try runOthers(othersRunning)
        } catch {
            stop()
            throw error
        }
    }

    /// Starts or stops the outputs but the main one. Each one started plays at once the frame the main
    /// output plays when it is heard, so a sound captured less than the delay ago is still heard whole.
    public func runOthers(_ run: Bool) throws {
        guard run != othersRunning else { return }
        othersRunning = run
        for output in outputs.dropFirst() {
            guard let procID = output.procID else { continue }
            if run {
                output.latency = output.device.outputLatency
                try check(AudioDeviceStart(output.device.id, procID), "start \(output.device.name)")
            } else {
                AudioDeviceStop(output.device.id, procID)
            }
        }
    }

    public func stop() {
        for output in outputs.dropFirst() {
            guard let procID = output.procID else { continue }
            AudioDeviceStop(output.device.id, procID)
            AudioDeviceDestroyIOProcID(output.device.id, procID)
            output.procID = nil
        }
        othersRunning = false
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        try? CA.setScalar(CA.system, kAudioHardwarePropertySleepingIsAllowed, 1)
    }

    /// Seconds an output needs the stream before the main output plays it: it is heard `lag` after the
    /// latency its device reports, and it reads one of its cycles (plus margin) ahead of the newest frame.
    public static func lead(of device: OutputDevice, lag: Double, main: OutputDevice) -> Double {
        guard device != main else { return 0 }
        let cycle = Double(max(512, device.bufferFrames)) / device.nominalSampleRate
        return max(0, device.outputLatency + lag - main.outputLatency + cycle + 0.005)
    }

    /// Host time (seconds) at which stream frame `frame` is heard on the main output.
    public func heardTime(ofFrame frame: Int) -> Double? {
        anchor.load().map { $0.time + Double(frame - $0.frame) / sampleRate }
    }

    /// Adds a calibration click to the captured sound at capture frame `frame`, after the main gain,
    /// so it is heard even while the main gain is 0. One click at a time; `frame` must be in the future.
    public func injectClick(atFrame frame: Int) { pendingClick.store(frame, ordering: .releasing) }
    public var clickLength: Int { click.count }


    // MARK: IO thread

    private func render(input: UnsafePointer<AudioBufferList>,
                        output: UnsafeMutablePointer<AudioBufferList>,
                        outputTime: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = min(Self.maxFrames, Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels)))
        if frames == 0 { return }
        let start = framesProcessed
        // Stream frame `start` is heard on the main output D frames after output frame 0 of this cycle.
        let ts = outputTime.pointee
        let heardAt = ts.mFlags.contains(.hostTimeValid)
            ? HostClock.seconds(ts.mHostTime) + (Double(outputLatencyFrames) + Double(delayFrames)) / sampleRate + Double(latencyTrim.value)
            : nil

        // 1. Input x main gain (+ calibration click) -> ring at framesProcessed.
        if let receiver {
            receiver.render(frames: frames, heardAt: heardAt, into: scratch)
        } else {
            readInput(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), frames: frames)
        }
        applyMainGain(frames: frames)
        addPendingClick(start: start, frames: frames)
        ring.write(scratch, frames: frames)
        framesProcessed = start + frames

        // 2. Ring -> main output, D frames behind, with a gain ramp.
        if !ring.read(at: start - delayFrames, frames: frames, into: scratch) {
            scratch.update(repeating: 0, count: frames * 2)
        }
        let main = outputs[0]
        let target = main.gain.value
        let step = (target - main.lastGain) / Float(frames)
        var gain = main.lastGain
        for i in 0..<frames {
            gain += step
            write(buffers, frame: i, left: scratch[2 * i] * gain, right: scratch[2 * i + 1] * gain)
        }
        main.lastGain = target

        // 3. Timeline.
        if let heardAt { anchor.store(Anchor(frame: start, time: heardAt)) }
    }

    /// Copies the capture twin's input (interleaved stereo, the device's only format) into `scratch`,
    /// and keeps its loudest sample.
    private func readInput(_ inputs: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let n = inputs.first.map { min(frames, Int($0.mDataByteSize) / (2 * MemoryLayout<Float>.size)) } ?? 0
        if n > 0, let data = inputs[0].mData { scratch.update(from: data.assumingMemoryBound(to: Float.self), count: 2 * n) }
        if n < frames { (scratch + 2 * n).update(repeating: 0, count: 2 * (frames - n)) }
        var peak = capturePeak.value
        for i in 0..<2 * n { peak = max(peak, abs(scratch[i])) }
        capturePeak.value = peak
    }

    /// Multiplies `scratch` by the main gain.
    private func applyMainGain(frames: Int) {
        let target = mainGain.value
        let step = (target - lastMainGain) / Float(frames)
        var gain = lastMainGain
        lastMainGain = target
        for i in 0..<2 * frames {
            if i & 1 == 0 { gain += step }
            scratch[i] *= gain
        }
    }

    private func addPendingClick(start: Int, frames: Int) {
        let at = pendingClick.load(ordering: .acquiring)
        guard at >= 0, at < start + frames else { return }
        for k in 0..<click.count where at + k >= start && at + k < start + frames {
            let p = (at + k - start) * 2
            scratch[p] += click[k]
            scratch[p + 1] += click[k]
        }
        if at + click.count <= start + frames {
            _ = pendingClick.compareExchange(expected: at, desired: -1, ordering: .acquiringAndReleasing)
        }
    }

    /// One cycle of an output other than the main one: it plays the frame the main output plays at the
    /// moment this output is heard, following the anchor on its own clock.
    private func follow(_ out: Output, rate: Double, output: UnsafeMutablePointer<AudioBufferList>, outputTime: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard let first = buffers.first, first.mNumberChannels > 0, let playhead = out.playhead, let sound = out.sound else { return }
        let frames = min(Self.maxFrames, Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels)))
        if frames == 0 { return }
        let ts = outputTime.pointee
        if ts.mFlags.contains(.hostTimeValid), let a = anchor.load() {
            let heardAt = HostClock.seconds(ts.mHostTime) + out.latency + Double(out.lag.value)
            let target = Double(a.frame) + (heardAt - a.time) * sampleRate
            let ring = ring
            var late = 0
            _ = playhead.render(target: target, rate: sampleRate, nominal: sampleRate / rate, frames: frames, gain: out.gain.value,
                                into: sound) { first, count, into in
                if ring.read(at: first, frames: count, into: into) { return 0 }
                into.update(repeating: 0, count: count * 2)
                if first >= 0, first + count > ring.writeIndex { late = count }
                return count
            }
            if late > 0 { out.missed.add(frames, ordering: .relaxed) }
        } else {
            sound.update(repeating: 0, count: frames * 2)
            playhead.reset()
        }
        for i in 0..<frames { write(buffers, frame: i, left: sound[2 * i], right: sound[2 * i + 1]) }
    }

    /// Writes one stereo frame into a device's buffers (first two channels; the rest stay silent).
    @inline(__always)
    private func write(_ buffers: UnsafeMutableAudioBufferListPointer, frame: Int, left: Float, right: Float) {
        let channels = Int(buffers[0].mNumberChannels)
        guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        if channels >= 2 {
            data[frame * channels] = left
            data[frame * channels + 1] = right
            for c in 2..<channels { data[frame * channels + c] = 0 }
        } else {
            data[frame] = left
            if buffers.count > 1 { buffers[1].mData?.assumingMemoryBound(to: Float.self)[frame] = right }
        }
    }
}
