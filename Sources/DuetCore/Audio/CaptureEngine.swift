import AudioToolbox
import CoreAudio
import Foundation

/// Captures the sound of every app on this Mac (the apps themselves go silent), and plays it back
/// on a local output device after a fixed delay. The same captured frames go to `ring` for the
/// network sender, together with an `anchor` that tells when each frame will be heard here.
///
/// Timeline: captured frame X is written to the delay line at position X and leaves it D frames
/// later. `anchor` holds (X, host time at which frame X is heard on this Mac's speaker).
public final class CaptureEngine: @unchecked Sendable {
    public enum Source: Sendable {
        /// Every process except the listed ones (the product: everything but Duet itself).
        case allExcept([pid_t])
        /// Only the listed processes (tests).
        case only([pid_t])
    }

    public let output: OutputDevice
    public let sampleRate: Double
    public let delayFrames: Int
    public let ring: FrameRing
    public let anchor = Anchor()
    /// Linear gain applied to this Mac's speaker only.
    public let localGain = AtomicFloat(1)
    /// Frames from the output callback to the ear, as reported by CoreAudio for the aggregate.
    public private(set) var outputLatencyFrames: UInt32 = 0
    /// Extra correction (seconds) for speakers that report their latency wrongly (set by calibration).
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
    private var lastGain: Float = 1
    private let ticksPerSecond: Double

    public init(source: Source, output: OutputDevice, delaySeconds: Double) {
        self.source = source
        self.output = output
        self.sampleRate = output.nominalSampleRate
        self.delayFrames = Int((delaySeconds * output.nominalSampleRate).rounded())
        var c = 1
        while c < delayFrames + 8192 { c <<= 1 }
        delayCapacity = c
        delayMask = c - 1
        delayLine = .allocate(capacity: c * 2)
        delayLine.initialize(repeating: 0, count: c * 2)
        ring = FrameRing(capacityFrames: Int(output.nominalSampleRate * 4))
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

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Duet",
            kAudioAggregateDeviceUIDKey: "duet.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create aggregate device")
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
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard let first = outputs.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        if frames == 0 { return }

        // 1. Captured frames -> delay line at position framesProcessed, and -> network ring.
        let start = framesProcessed
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if !copyInput(inputs, frames: frames, to: start) {
            for i in 0..<frames {
                let p = ((start + i) & delayMask) * 2
                delayLine[p] = 0; delayLine[p + 1] = 0
            }
        }
        var written = 0
        while written < frames {
            let pos = (start + written) & delayMask
            let n = min(frames - written, delayCapacity - pos)
            ring.write(delayLine + pos * 2, frames: n)
            written += n
        }

        // 2. Delay line -> output, D frames behind, with a gain ramp.
        let target = localGain.value
        let step = (target - lastGain) / Float(frames)
        var gain = lastGain
        let readStart = start - delayFrames
        for i in 0..<frames {
            gain += step
            let p = ((readStart + i) & delayMask) * 2
            let l = readStart + i >= 0 ? delayLine[p] * gain : 0
            let r = readStart + i >= 0 ? delayLine[p + 1] * gain : 0
            writeOutput(outputs, frame: i, left: l, right: r)
        }
        lastGain = target
        framesProcessed = start + frames

        // 3. Timeline: captured frame `start` is heard D frames after output frame 0 of this cycle.
        let ts = outputTime.pointee
        if ts.mFlags.contains(.hostTimeValid) {
            let seconds = (Double(outputLatencyFrames) + Double(delayFrames)) / sampleRate + Double(latencyTrim.value)
            anchor.store(Int64(start), ts.mHostTime &+ UInt64(max(0, seconds * ticksPerSecond)))
        }
    }

    /// Copies the tap's stereo input into the delay line. Handles interleaved and planar layouts.
    private func copyInput(_ inputs: UnsafeMutableAudioBufferListPointer, frames: Int, to start: Int) -> Bool {
        guard inputs.count > 0, let data0 = inputs[0].mData else { return false }
        let ch0 = Int(inputs[0].mNumberChannels)
        let src0 = data0.assumingMemoryBound(to: Float.self)
        let available0 = Int(inputs[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, ch0))
        let n = min(frames, available0)
        if ch0 >= 2 {
            for i in 0..<n {
                let p = ((start + i) & delayMask) * 2
                delayLine[p] = src0[i * ch0]
                delayLine[p + 1] = src0[i * ch0 + 1]
            }
        } else if inputs.count >= 2, let data1 = inputs[1].mData {
            let src1 = data1.assumingMemoryBound(to: Float.self)
            for i in 0..<n {
                let p = ((start + i) & delayMask) * 2
                delayLine[p] = src0[i]
                delayLine[p + 1] = src1[i]
            }
        } else {
            for i in 0..<n {
                let p = ((start + i) & delayMask) * 2
                delayLine[p] = src0[i]
                delayLine[p + 1] = src0[i]
            }
        }
        for i in n..<frames {
            let p = ((start + i) & delayMask) * 2
            delayLine[p] = 0; delayLine[p + 1] = 0
        }
        return true
    }

    @inline(__always)
    private func writeOutput(_ outputs: UnsafeMutableAudioBufferListPointer, frame: Int, left: Float, right: Float) {
        if outputs.count == 1 || outputs[0].mNumberChannels >= 2 {
            let channels = Int(outputs[0].mNumberChannels)
            guard let data = outputs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            data[frame * channels] = left
            if channels > 1 { data[frame * channels + 1] = right }
            for c in 2..<max(2, channels) { data[frame * channels + c] = 0 }
        } else {
            outputs[0].mData?.assumingMemoryBound(to: Float.self)[frame] = left
            outputs[1].mData?.assumingMemoryBound(to: Float.self)[frame] = right
        }
    }
}
