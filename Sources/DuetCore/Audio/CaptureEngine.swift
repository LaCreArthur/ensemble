import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Captures the sound of every app on this Mac (the apps themselves go silent), and plays it back
/// on one or more local output devices after a fixed delay. The same captured frames go to `ring`
/// for the network sender, together with an `anchor` that tells when each frame will be heard here.
///
/// Timeline: captured frame X is written to the delay line at position X and the main output plays
/// it D frames later. `anchor` holds (X, host time at which frame X is heard on the main output).
/// Every other output is heard `lag` seconds after the main output for the same cycle, so it plays
/// frame X `lag` earlier in its own channels, and all outputs are heard together.
public final class CaptureEngine: @unchecked Sendable {
    public enum Source: Sendable {
        /// Every process except the listed ones (the product: everything but Duet itself).
        case allExcept([pid_t])
        /// Only the listed processes (tests).
        case only([pid_t])
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
    public let anchor = Anchor()
    /// Linear gain on the captured sound, before every output (this Mac and the network).
    public let mainGain = AtomicFloat(1)
    /// Frames from the output callback to the ear, as reported by CoreAudio for the aggregate (main output first).
    public private(set) var outputLatencyFrames: UInt32 = 0
    /// Extra correction (seconds) for a main output that reports its latency wrongly.
    public let latencyTrim = AtomicFloat(0)

    private let source: Source
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // Delay line, touched only by the IO thread after start.
    private let delayCapacity: Int
    private let delayMask: Int
    private let delayLine: UnsafeMutablePointer<Float>
    private var framesProcessed: Int = 0
    private var lastMainGain: Float = 1
    private let ticksPerSecond: Double
    /// Lags beyond this are not supported (the delay line holds D plus this much).
    private static let maxLagSeconds = 1.0

    private let pendingClick = Atomic<Int>(-1)
    private let click: [Float]

    public init(source: Source, outputs: [OutputDevice], delaySeconds: Double) {
        precondition(!outputs.isEmpty)
        self.source = source
        self.outputs = outputs.map(Output.init)
        sampleRate = outputs[0].nominalSampleRate
        delayFrames = Int((delaySeconds * sampleRate).rounded())
        var c = 1
        while c < delayFrames + Int(Self.maxLagSeconds * sampleRate) + 8192 { c <<= 1 }
        delayCapacity = c
        delayMask = c - 1
        delayLine = .allocate(capacity: c * 2)
        delayLine.initialize(repeating: 0, count: c * 2)
        ring = FrameRing(capacityFrames: Int(sampleRate * 4))
        click = AcousticProbe.clickWaveform(sampleRate: sampleRate).map { $0 * 0.3 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }

    deinit {
        stop()
        delayLine.deallocate()
    }

    public func start() throws {
        let tap = try makeTapDescription()
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap")

        let main = outputs[0].device
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Duet",
            kAudioAggregateDeviceUIDKey: "duet.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: main.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: outputs.map { output -> [String: Any] in
                [kAudioSubDeviceUIDKey: output.device.uid, kAudioSubDeviceDriftCompensationKey: output.device.uid != main.uid]
            },
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
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

    /// Host ticks per second (mach_absolute_time).
    public var hostTicksPerSecond: Double { ticksPerSecond }

    /// Adds a calibration click to the captured sound at capture frame `frame`, after the main gain,
    /// so it is heard even while the main gain is 0. One click at a time; `frame` must be in the future.
    public func injectClick(atFrame frame: Int) { pendingClick.store(frame, ordering: .releasing) }
    public var clickLength: Int { click.count }

    private func makeTapDescription() throws -> CATapDescription {
        let description: CATapDescription
        switch source {
        case .allExcept(let pids):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: try pids.map(processObject(for:)))
        case .only(let pids):
            description = CATapDescription(stereoMixdownOfProcesses: try pids.map(processObject(for:)))
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
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        if frames == 0 { return }

        // 1. Captured frames x main gain (+ calibration click) -> delay line at framesProcessed, and -> ring.
        let start = framesProcessed
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        copyInput(inputs, frames: frames, to: start)
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

        // 3. Timeline: captured frame `start` is heard on the main output D frames after output frame 0 of this cycle.
        let ts = outputTime.pointee
        if ts.mFlags.contains(.hostTimeValid) {
            let seconds = (Double(outputLatencyFrames) + Double(delayFrames)) / sampleRate + Double(latencyTrim.value)
            anchor.store(Int64(start), ts.mHostTime &+ UInt64(max(0, seconds * ticksPerSecond)))
        }
    }

    /// Copies the tap's stereo input, times the main gain, into the delay line (interleaved or planar).
    private func copyInput(_ inputs: UnsafeMutableAudioBufferListPointer, frames: Int, to start: Int) {
        let target = mainGain.value
        let step = (target - lastMainGain) / Float(frames)
        var gain = lastMainGain
        lastMainGain = target
        var n = 0
        if inputs.count > 0, let data0 = inputs[0].mData {
            let ch0 = Int(inputs[0].mNumberChannels)
            let src0 = data0.assumingMemoryBound(to: Float.self)
            n = min(frames, Int(inputs[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, ch0)))
            let src1: UnsafeMutablePointer<Float>? = ch0 < 2 && inputs.count >= 2 ? inputs[1].mData?.assumingMemoryBound(to: Float.self) : nil
            for i in 0..<n {
                gain += step
                let p = ((start + i) & delayMask) * 2
                let l = ch0 >= 2 ? src0[i * ch0] : src0[i]
                let r = ch0 >= 2 ? src0[i * ch0 + 1] : (src1?[i] ?? src0[i])
                delayLine[p] = l * gain
                delayLine[p + 1] = r * gain
            }
        }
        for i in n..<frames {
            let p = ((start + i) & delayMask) * 2
            delayLine[p] = 0; delayLine[p + 1] = 0
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
