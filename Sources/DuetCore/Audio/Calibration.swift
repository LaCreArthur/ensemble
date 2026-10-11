import CoreAudio
import Foundation

/// Measures with the microphone when each output is heard compared with the main output, and sets
/// each output's lag so that all outputs are heard together. Clicks go through the real path
/// (delay line, aggregate, device), so everything the devices do not report is included.
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

    public static func run(_ engine: CaptureEngine, microphone: AudioObjectID, clicks: Int = 6) throws -> [Measurement] {
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
        let perOutput = delay + Double(clicks) * spacing + 0.3
        nonisolated(unsafe) var references = [[Double]](repeating: [], count: engine.outputs.count)
        let done = DispatchSemaphore(value: 0)
        let recording = try probe.record(device: microphone, duration: Double(engine.outputs.count) * perOutput + 0.6) {
            DispatchQueue.global(qos: .userInteractive).async {
                Thread.sleep(forTimeInterval: 0.3)
                for o in engine.outputs.indices {
                    for (i, other) in engine.outputs.enumerated() { other.gain.value = i == o ? savedGains[i] : 0 }
                    for _ in 0..<clicks {
                        let frame = engine.ring.writeIndex + Int(0.05 * rate)
                        engine.injectClick(atFrame: frame)
                        if let (anchorFrame, anchorTicks) = engine.anchor.load() {
                            references[o].append(probe.seconds(anchorTicks) + Double(frame - Int(anchorFrame)) / rate)
                        }
                        Thread.sleep(forTimeInterval: spacing)
                    }
                    Thread.sleep(forTimeInterval: delay + 0.05)
                }
                done.signal()
            }
        }
        done.wait()
        let measured: [Measurement] = zip(engine.outputs, references).map { output, refs in
            // Most clicks must be clearly heard; the median ignores a click masked by a noise.
            let heard = probe.detect(in: recording, references: refs, minDelay: -0.1, maxDelay: 0.25).compactMap(\.first).filter { $0.strength >= 8 }
            let strength = heard.map(\.strength).sorted().first ?? 0
            guard heard.count * 3 >= refs.count * 2, !refs.isEmpty else {
                return Measurement(output: output.device.name, delay: nil, strength: strength)
            }
            let sorted = heard.map(\.delay).sorted()
            return Measurement(output: output.device.name, delay: sorted[sorted.count / 2], strength: strength)
        }
        if let main = measured[0].delay {
            for (output, m) in zip(engine.outputs, measured).dropFirst() {
                if let d = m.delay { output.lag.value += Float(d - main) }
            }
        }
        let results = measured
        return results
    }
}
