import CoreAudio
import Foundation

/// Measures with the microphone when each output is heard compared with the main output, and sets
/// each output's lag so that all outputs are heard together. Clicks go through the real path
/// (delay line, aggregate, device), so everything the devices do not report is included.
/// The other Mac, if given, is measured last as one more output; the caller applies its result.
/// The music is muted while it runs (about 2 s per output).
public enum Calibration {
    public struct Measurement: Sendable {
        public let output: String
        /// Seconds between the predicted and the measured arrival at the microphone (median); nil if
        /// not heard. Includes the microphone's own delay, which is the same for every output.
        public let delay: Double?
        /// Weakest heard click's detection strength (an SNR; 8 or more counts as heard).
        public let strength: Double
    }

    /// The other Mac, while it plays the same stream as this Mac: `solo(true)` makes it the only one
    /// that plays the stream's clicks, `solo(false)` silences it, and `click` makes a click come
    /// through the stream soon. Called from a background thread.
    public struct OtherMac: Sendable {
        public let name: String
        public let solo: @Sendable (Bool) -> Void
        public let click: @Sendable () -> Void
        public init(name: String, solo: @escaping @Sendable (Bool) -> Void, click: @escaping @Sendable () -> Void) {
            self.name = name
            self.solo = solo
            self.click = click
        }
    }

    public static func run(_ engine: Engine, microphone: AudioObjectID, other: OtherMac? = nil, clicks: Int = 6) throws -> [Measurement] {
        let probe = AcousticProbe()
        let rate = engine.sampleRate
        let delay = Double(engine.delayFrames) / rate
        let spacing = 0.2
        let savedMain = engine.mainGain.value
        let savedGains = engine.outputs.map { $0.gain.value }
        defer {
            engine.mainGain.value = savedMain
            for (output, gain) in zip(engine.outputs, savedGains) { output.gain.value = gain }
        }
        engine.mainGain.value = 0
        other?.solo(false)
        let perOutput = delay + Double(clicks) * spacing + 0.3
        let otherTime = other == nil ? 0 : Double(clicks) * spacing + 1
        nonisolated(unsafe) var references = [[Double]](repeating: [], count: engine.outputs.count)
        let done = DispatchSemaphore(value: 0)
        let duration = Double(engine.outputs.count) * perOutput + otherTime + 0.6
        let recording = try probe.record(device: microphone, duration: duration) {
            DispatchQueue.global(qos: .userInteractive).async {
                Thread.sleep(forTimeInterval: 0.3)
                for o in engine.outputs.indices {
                    // The main output is the reference, so it clicks even when not ticked.
                    let gain = o == 0 && savedGains[0] == 0 ? 1 : savedGains[o]
                    for (i, output) in engine.outputs.enumerated() { output.gain.value = i == o ? gain : 0 }
                    for _ in 0..<clicks {
                        let frame = engine.ring.writeIndex + Int(0.05 * rate)
                        engine.injectClick(atFrame: frame)
                        if let heard = engine.heardTime(ofFrame: frame) { references[o].append(heard) }
                        Thread.sleep(forTimeInterval: spacing)
                    }
                    Thread.sleep(forTimeInterval: delay + 0.05)
                }
                if let other {
                    for output in engine.outputs { output.gain.value = 0 }
                    other.solo(true)
                    let first = engine.ring.writeIndex
                    for _ in 0..<clicks {
                        other.click()
                        Thread.sleep(forTimeInterval: spacing)
                    }
                    Thread.sleep(forTimeInterval: 0.6)
                    references.append(clickTimes(in: engine, frames: first..<engine.ring.writeIndex))
                    other.solo(false)
                }
                done.signal()
            }
        }
        done.wait()
        let names = engine.outputs.map(\.device.name) + (other.map { [$0.name] } ?? [])
        let measured: [Measurement] = zip(names, references).map { name, refs in
            // Most clicks must be clearly heard; the median ignores a click masked by a noise.
            let heard = probe.detect(in: recording, references: refs, minDelay: -0.1, maxDelay: 0.25).compactMap(\.first).filter { $0.strength >= 8 }
            let strength = heard.map(\.strength).sorted().first ?? 0
            guard heard.count * 3 >= refs.count * 2, !refs.isEmpty else {
                return Measurement(output: name, delay: nil, strength: strength)
            }
            let sorted = heard.map(\.delay).sorted()
            return Measurement(output: name, delay: sorted[sorted.count / 2], strength: strength)
        }
        if let main = measured[0].delay {
            for (output, m) in zip(engine.outputs, measured).dropFirst() {
                if let d = m.delay { output.lag.value += Float(d - main) }
            }
        }
        return measured
    }

    /// Host times at which the clicks in `frames` of the engine's stream are heard on its main output,
    /// which is when the other Mac plays them if both are in sync.
    private static func clickTimes(in engine: Engine, frames: Range<Int>) -> [Double] {
        let click = AcousticProbe.clickWaveform(sampleRate: engine.sampleRate)
        let n = frames.count - click.count
        var stereo = [Float](repeating: 0, count: frames.count * 2)
        guard n > 0, stereo.withUnsafeMutableBufferPointer({ engine.ring.read(at: frames.lowerBound, frames: frames.count, into: $0.baseAddress!) })
        else { return [] }
        let y = (0..<n).map { i in
            var dot: Float = 0
            for k in click.indices { dot += stereo[2 * (i + k)] * click[k] }
            return dot
        }
        // Clicks are the stream's only sound meanwhile; below a click of amplitude 0.05 is no click.
        let floor = 0.05 * click.reduce(0) { $0 + $1 * $1 }
        guard let peak = y.max(), peak > floor else { return [] }
        var times = [Double](), i = 0
        while i < n {
            guard y[i] >= peak / 2 else { i += 1; continue }
            let best = (i..<min(n, i + click.count)).max { y[$0] < y[$1] }!
            if let time = engine.heardTime(ofFrame: frames.lowerBound + best) { times.append(time) }
            i = best + Int(0.1 * engine.sampleRate)
        }
        return times
    }
}
