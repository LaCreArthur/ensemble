import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Plays one stereo stream on one or more local output devices, all heard together. The stream is
/// either the sound of this Mac's apps, captured (the apps themselves go silent) and played after a
/// fixed delay that gives the other Mac time to receive it, or the sound the other Mac sends. The
/// stream's frames go to `ring`, and `anchor` tells when each frame is heard here.
///
/// Timeline: stream frame X is written to the delay line at position X and the main output plays it
/// D frames later. `anchor` holds X and the host time at which frame X is heard on the main output.
/// Every other output is heard `lag` seconds after the main output for the same cycle, so it plays
/// frame X `lag` earlier in its own channels, and all outputs are heard together.
public final class Engine: @unchecked Sendable {
    public enum Input: Sendable {
        /// The sound of every process except the listed ones (the product: everything but Duet itself).
        case captureAllExcept([pid_t])
        /// The sound of the listed processes only (tests).
        case captureOnly([pid_t])
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
        /// Seconds this output is heard after the main output when both play the same cycle
        /// (latency the device does not report, for example a screen's own processing).
        public let lag = AtomicFloat(0)
        // Its buffers in the aggregate's output list (set at start), and IO-thread state.
        fileprivate var buffers: Range<Int> = 0..<0
        fileprivate var lastGain: Float = 1

        public init(device: OutputDevice) { self.device = device }
    }

    /// outputs[0] is the main output: its clock drives the engine and `anchor` refers to it.
    public let outputs: [Output]
    public let sampleRate: Double
    public let delayFrames: Int
    public let ring: FrameRing
    public let anchor = SeqLock<Anchor?>(nil)
    /// Linear gain on the stream, before every output of this Mac (and the network).
    public let mainGain = AtomicFloat(1)
    /// Frames from the output callback to the ear, as reported by CoreAudio for the aggregate (main output first).
    public private(set) var outputLatencyFrames: UInt32 = 0
    /// Extra correction (seconds) for a main output that reports its latency wrongly.
    public let latencyTrim = AtomicFloat(0)

    private let input: Input
    private let receiver: StreamReceiver?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // Delay line, touched only by the IO thread after start.
    private let delayCapacity: Int
    private let delayMask: Int
    private let delayLine: UnsafeMutablePointer<Float>
    private var framesProcessed: Int = 0
    private var lastMainGain: Float = 1
    /// One cycle of the input, interleaved stereo.
    private let scratch: UnsafeMutablePointer<Float>
    private static let maxFrames = 16_384
    /// Lags beyond this are not supported (the delay line holds D plus this much).
    private static let maxLagSeconds = 1.0

    private let pendingClick = Atomic<Int>(-1)
    private let click: [Float]

    public init(input: Input, outputs: [OutputDevice], delaySeconds: Double, sourceRate: Double = 0) {
        precondition(!outputs.isEmpty)
        self.input = input
        if case .network(let receiver) = input { self.receiver = receiver } else { receiver = nil }
        self.outputs = outputs.map(Output.init)
        sampleRate = outputs[0].nominalSampleRate
        receiver?.prepare(outputRate: sampleRate, sourceRate: sourceRate > 0 ? sourceRate : sampleRate)
        scratch = .allocate(capacity: Self.maxFrames * 2)
        delayFrames = Int((delaySeconds * sampleRate).rounded())
        var c = 1
        while c < delayFrames + Int(Self.maxLagSeconds * sampleRate) + 8192 { c <<= 1 }
        delayCapacity = c
        delayMask = c - 1
        delayLine = .allocate(capacity: c * 2)
        delayLine.initialize(repeating: 0, count: c * 2)
        ring = FrameRing(capacityFrames: Int(sampleRate * 4))
        click = AcousticProbe.clickWaveform(sampleRate: sampleRate).map { $0 * 0.3 }
    }

    deinit {
        stop()
        delayLine.deallocate()
        scratch.deallocate()
    }

    public func start() throws {
        let tap = try makeTapDescription()
        if let tap { try check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap") }

        let main = outputs[0].device
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Duet",
            kAudioAggregateDeviceUIDKey: "duet.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: main.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: outputs.map { output -> [String: Any] in
                [kAudioSubDeviceUIDKey: output.device.uid, kAudioSubDeviceDriftCompensationKey: output.device.uid != main.uid]
            },
        ]
        if let tap {
            description[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        }
        do {
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create aggregate device")
            // The aggregate lists each sub-device's output buffers in sub-device order.
            var next = 0
            for output in outputs {
                let count = CA.bufferCount(output.device.id, kAudioObjectPropertyScopeOutput)
                output.buffers = next..<(next + count)
                next += count
            }
            outputLatencyFrames = Self.outputLatency(of: aggregateID)
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [unowned self] _, input, _, output, outputTime in
                self.render(input: input, output: output, outputTime: outputTime)
            }, "create IO proc")
            try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
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

    /// The aggregate's IO buffer size, output safety offset, and input latency (device + stream +
    /// safety offset), in frames, for diagnosis.
    public var ioFrames: (buffer: UInt32, safety: UInt32, inputLatency: UInt32) {
        let input = kAudioObjectPropertyScopeInput
        let streams = (try? CA.array(aggregateID, kAudioDevicePropertyStreams, input, as: AudioObjectID.self)) ?? []
        let streamLatency = streams.first.flatMap { try? CA.scalar($0, kAudioStreamPropertyLatency, as: UInt32.self) } ?? 0
        let inputLatency = ((try? CA.scalar(aggregateID, kAudioDevicePropertyLatency, input, as: UInt32.self)) ?? 0) + streamLatency
            + ((try? CA.scalar(aggregateID, kAudioDevicePropertySafetyOffset, input, as: UInt32.self)) ?? 0)
        return ((try? CA.scalar(aggregateID, kAudioDevicePropertyBufferFrameSize, as: UInt32.self)) ?? 0,
                (try? CA.scalar(aggregateID, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, as: UInt32.self)) ?? 0,
                inputLatency)
    }

    /// Host time (seconds) at which stream frame `frame` is heard on the main output.
    public func heardTime(ofFrame frame: Int) -> Double? {
        anchor.load().map { $0.time + Double(frame - $0.frame) / sampleRate }
    }

    /// Adds a calibration click to the captured sound at capture frame `frame`, after the main gain,
    /// so it is heard even while the main gain is 0. One click at a time; `frame` must be in the future.
    public func injectClick(atFrame frame: Int) { pendingClick.store(frame, ordering: .releasing) }
    public var clickLength: Int { click.count }

    private func makeTapDescription() throws -> CATapDescription? {
        let description: CATapDescription
        switch input {
        case .captureAllExcept(let pids):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: try pids.map(processObject(for:)))
        case .captureOnly(let pids):
            description = CATapDescription(stereoMixdownOfProcesses: try pids.map(processObject(for:)))
        case .network:
            return nil
        }
        description.uuid = UUID()
        description.name = "Duet"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private static func outputLatency(of device: AudioObjectID) -> UInt32 {
        let deviceLatency = (try? CA.scalar(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, as: UInt32.self)) ?? 0
        let streams = (try? CA.array(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, as: AudioObjectID.self)) ?? []
        let streamLatency = streams.first.flatMap { try? CA.scalar($0, kAudioStreamPropertyLatency, as: UInt32.self) } ?? 0
        return deviceLatency + streamLatency
    }

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

        // 1. Input x main gain (+ calibration click) -> delay line at framesProcessed, and -> ring.
        if let receiver {
            receiver.render(frames: frames, heardAt: heardAt, into: scratch)
        } else {
            readTap(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), frames: frames)
        }
        copyScratch(frames: frames, to: start)
        addPendingClick(start: start, frames: frames)
        var written = 0
        while written < frames {
            let pos = (start + written) & delayMask
            let n = min(frames - written, delayCapacity - pos)
            ring.write(delayLine + pos * 2, frames: n)
            written += n
        }

        // 2. Delay line -> each output, D frames behind minus its lag, with a gain ramp.
        for out in outputs where !out.buffers.isEmpty && out.buffers.upperBound <= buffers.count {
            let target = out.gain.value
            let step = (target - out.lastGain) / Float(frames)
            var gain = out.lastGain
            let lagFrames = Int((Double(out.lag.value) * sampleRate).rounded())
            let readStart = start - delayFrames + max(-Int(Self.maxLagSeconds * sampleRate), min(delayFrames, lagFrames))
            for i in 0..<frames {
                gain += step
                let x = readStart + i
                let p = (x & delayMask) * 2
                let l = x >= 0 ? delayLine[p] * gain : 0
                let r = x >= 0 ? delayLine[p + 1] * gain : 0
                write(buffers, out.buffers, frame: i, left: l, right: r)
            }
            out.lastGain = target
        }
        framesProcessed = start + frames

        // 3. Timeline.
        if let heardAt { anchor.store(Anchor(frame: start, time: heardAt)) }
    }

    /// Copies the tap's stereo input (interleaved or planar) into `scratch`.
    private func readTap(_ inputs: UnsafeMutableAudioBufferListPointer, frames: Int) {
        var n = 0
        if inputs.count > 0, let data0 = inputs[0].mData {
            let ch0 = Int(inputs[0].mNumberChannels)
            let src0 = data0.assumingMemoryBound(to: Float.self)
            n = min(frames, Int(inputs[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, ch0)))
            let src1: UnsafeMutablePointer<Float>? = ch0 < 2 && inputs.count >= 2 ? inputs[1].mData?.assumingMemoryBound(to: Float.self) : nil
            for i in 0..<n {
                scratch[2 * i] = ch0 >= 2 ? src0[i * ch0] : src0[i]
                scratch[2 * i + 1] = ch0 >= 2 ? src0[i * ch0 + 1] : (src1?[i] ?? src0[i])
            }
        }
        if n < frames { (scratch + 2 * n).update(repeating: 0, count: 2 * (frames - n)) }
    }

    /// Copies `scratch`, times the main gain, into the delay line.
    private func copyScratch(frames: Int, to start: Int) {
        let target = mainGain.value
        let step = (target - lastMainGain) / Float(frames)
        var gain = lastMainGain
        lastMainGain = target
        for i in 0..<frames {
            gain += step
            let p = ((start + i) & delayMask) * 2
            delayLine[p] = scratch[2 * i] * gain
            delayLine[p + 1] = scratch[2 * i + 1] * gain
        }
    }

    private func addPendingClick(start: Int, frames: Int) {
        let at = pendingClick.load(ordering: .acquiring)
        guard at >= 0, at < start + frames else { return }
        for k in 0..<click.count where at + k >= start && at + k < start + frames {
            let p = ((at + k) & delayMask) * 2
            delayLine[p] += click[k]
            delayLine[p + 1] += click[k]
        }
        if at + click.count <= start + frames {
            _ = pendingClick.compareExchange(expected: at, desired: -1, ordering: .acquiringAndReleasing)
        }
    }

    /// Writes one stereo frame into a device's buffers (first two channels; the rest stay silent).
    @inline(__always)
    private func write(_ buffers: UnsafeMutableAudioBufferListPointer, _ range: Range<Int>, frame: Int, left: Float, right: Float) {
        let b = range.lowerBound
        let channels = Int(buffers[b].mNumberChannels)
        guard let data = buffers[b].mData?.assumingMemoryBound(to: Float.self) else { return }
        if channels >= 2 {
            data[frame * channels] = left
            data[frame * channels + 1] = right
            for c in 2..<channels { data[frame * channels + c] = 0 }
        } else {
            data[frame] = left
            if range.count > 1 { buffers[b + 1].mData?.assumingMemoryBound(to: Float.self)[frame] = right }
        }
    }
}
