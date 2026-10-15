import CoreAudio
import Foundation

/// Plays a train of short clicks on an output device and listens with a microphone, so that the
/// time between "a click leaves" and "a click is heard" can be measured in host time.
/// Used to prove sync between the two Macs and to calibrate it.
public final class AcousticProbe: @unchecked Sendable {
    public struct Arrival: Sendable {
        /// Seconds between the click reference time and the detected arrival at the microphone.
        public let delay: Double
        /// Normalized matched-filter peak (0...1). Below ~0.2 the click was not really heard.
        public let strength: Double
    }

    /// The click: 1.5 ms of a 4 kHz tone burst with a Hann window. Short, broadband enough to time.
    public static func clickWaveform(sampleRate: Double) -> [Float] {
        let n = Int(sampleRate * 0.0015)
        return (0..<n).map { i in
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            return Float(w * sin(2 * Double.pi * 4000 * Double(i) / sampleRate))
        }
    }

    private let ticksPerSecond: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return 1e9 * Double(tb.denom) / Double(tb.numer)
    }()

    public init() {}

    public func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }
    public func now() -> Double { seconds(mach_absolute_time()) }

    // MARK: Recording

    public final class Recording: @unchecked Sendable {
        public let sampleRate: Double
        public var samples: [Float] = []
        /// Host time (seconds) at which samples[0] reached the microphone.
        public var startTime: Double = 0
        init(sampleRate: Double) { self.sampleRate = sampleRate }
    }

    /// Records mono audio from an input device for `duration` seconds (blocking).
    public func record(device: AudioObjectID, duration: Double, during: (() -> Void)? = nil) throws -> Recording {
        let rate = (try? CA.scalar(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 48_000
        let inputLatency = Double(((try? CA.scalar(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput, as: UInt32.self)) ?? 0)
            + ((try? CA.scalar(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, as: UInt32.self)) ?? 0)) / rate
        let recording = Recording(sampleRate: rate)
        let capacity = Int(rate * (duration + 1))
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var count = 0
        var firstHost: UInt64 = 0
        let lock = NSLock()
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, inputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let b = list.first, let data = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = Int(b.mNumberChannels)
            let frames = Int(b.mDataByteSize) / (4 * max(1, channels))
            lock.lock()
            if count == 0 { firstHost = inputTime.pointee.mHostTime }
            let n = min(frames, capacity - count)
            for i in 0..<n { buffer[count + i] = data[i * channels] }
            count += n
            lock.unlock()
        }, "create input IO proc")
        try check(AudioDeviceStart(device, proc), "start input")
        during?()
        Thread.sleep(forTimeInterval: duration)
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc!)
        lock.lock(); defer { lock.unlock() }
        recording.samples = Array(UnsafeBufferPointer(start: buffer, count: count))
        // The sample stamped at inputTime was heard by the mic `inputLatency` earlier.
        recording.startTime = seconds(firstHost) - inputLatency
        return recording
    }

    // MARK: Click playback on a single device (no Ensemble in the path)

    /// Plays clicks at the given host times (seconds) on an output device, blocking until done.
    /// Returns the host times at which each click actually left the speaker (latency-corrected).
    public func playClicks(device: AudioObjectID, at times: [Double], amplitude: Float = 0.3) throws -> [Double] {
        let rate = (try? CA.scalar(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 48_000
        let latency = Double(CA.outputLatencyFrames(device)) / rate
        let click = Self.clickWaveform(sampleRate: rate).map { $0 * amplitude }
        var emitted = [Double](repeating: 0, count: times.count)
        let lock = NSLock()
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [ticksPerSecond] _, _, _, output, outputTime in
            let list = UnsafeMutableAudioBufferListPointer(output)
            guard let b = list.first, let data = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = Int(b.mNumberChannels)
            let frames = Int(b.mDataByteSize) / (4 * max(1, channels))
            // Time at which output frame 0 of this buffer is heard.
            let t0 = Double(outputTime.pointee.mHostTime) / ticksPerSecond + latency
            for i in 0..<frames {
                let t = t0 + Double(i) / rate
                var v: Float = 0
                for (k, start) in times.enumerated() {
                    let idx = Int(((t - start) * rate).rounded())
                    if idx >= 0 && idx < click.count {
                        v = click[idx]
                        if idx == 0 { lock.lock(); emitted[k] = t; lock.unlock() }
                    }
                }
                for c in 0..<channels { data[i * channels + c] = v }
            }
        }, "create output IO proc")
        try check(AudioDeviceStart(device, proc), "start output")
        let end = (times.max() ?? now()) + 0.2
        while now() < end { Thread.sleep(forTimeInterval: 0.05) }
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc!)
        lock.lock(); defer { lock.unlock() }
        return emitted
    }

    // MARK: Detection

    /// Finds click arrivals inside [reference + minDelay, reference + maxDelay] for each reference time.
    /// `strength` is the matched-filter peak over the window's robust noise level (an SNR; real
    /// clicks score well above 8). With `peaks == 1` the earliest strong arrival (the direct path,
    /// not a wall reflection) is returned; with more, the strongest distinct ones, sorted by time.
    public func detect(in recording: Recording, references: [Double], minDelay: Double, maxDelay: Double,
                       peaks: Int = 1, separation: Double = 0.004) -> [[Arrival]] {
        let rate = recording.sampleRate
        let click = Self.clickWaveform(sampleRate: rate)
        return references.map { ref in
            let from = Int(((ref + minDelay) - recording.startTime) * rate)
            let to = Int(((ref + maxDelay) - recording.startTime) * rate)
            guard from >= 0, to + click.count < recording.samples.count, to > from else { return [] }
            var y = [Float](repeating: 0, count: to - from)
            recording.samples.withUnsafeBufferPointer { s in
                for i in from..<to {
                    var dot: Float = 0
                    for k in 0..<click.count { dot += s[i + k] * click[k] }
                    y[i - from] = abs(dot)
                }
            }
            let sorted = y.sorted()
            let noise = Double(max(sorted[sorted.count / 2] * 1.4826, 1e-9))
            guard let maxValue = sorted.last else { return [] }
            func isLocalMax(_ j: Int) -> Bool { (j == 0 || y[j] >= y[j - 1]) && (j == y.count - 1 || y[j] >= y[j + 1]) }
            func arrival(_ j: Int) -> Arrival {
                Arrival(delay: recording.startTime + Double(from + j) / rate - ref, strength: Double(y[j]) / noise)
            }
            if peaks == 1 {
                // Earliest local maximum reaching half of the strongest peak.
                guard let j = y.indices.first(where: { y[$0] >= maxValue * 0.5 && isLocalMax($0) }) else { return [] }
                return [arrival(j)]
            }
            var found = [Int]()
            for j in y.indices.sorted(by: { y[$0] > y[$1] }) {
                if found.count >= peaks || Double(y[j]) / noise < 8 { break }
                if found.contains(where: { abs($0 - j) < Int(separation * rate) }) { continue }
                found.append(j)
            }
            return found.sorted().map(arrival)
        }
    }
}
