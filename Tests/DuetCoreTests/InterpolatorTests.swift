import Foundation
import Testing
@testable import DuetCore

/// Reading the sound between its samples, which is how an output on its own clock plays the same
/// sound a little faster or slower without the pitch changing or the level moving.
struct InterpolatorTests {
    let rate = 48_000.0
    let frequency = 1_000.0

    /// Interleaved stereo: left a sine, right a cosine, so a swapped channel is visible.
    func tone(frames: Int) -> [Float] {
        var signal = [Float](repeating: 0, count: frames * 2)
        for n in 0..<frames {
            signal[2 * n] = Float(left(Double(n)))
            signal[2 * n + 1] = Float(right(Double(n)))
        }
        return signal
    }

    func left(_ position: Double) -> Double { sin(2 * .pi * frequency * position / rate) }
    func right(_ position: Double) -> Double { cos(2 * .pi * frequency * position / rate) }

    func render(_ interpolator: Interpolator, _ input: [Float], start: Double, step: Double, count: Int,
                gain: (Float, Float) = (1, 1)) -> [Float] {
        var output = [Float](repeating: .nan, count: count * 2)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                interpolator.render(input: source.baseAddress!, inputStart: 0, start: start, step: step,
                                    count: count, gain: gain, into: destination.baseAddress!)
            }
        }
        return output
    }

    /// Largest difference between the rendered tone and the tone at the positions it was asked for.
    func error(_ output: [Float], start: Double, step: Double) -> Double {
        var worst = 0.0
        for i in 0..<(output.count / 2) {
            let position = start + Double(i) * step
            worst = max(worst, abs(Double(output[2 * i]) - left(position)))
            worst = max(worst, abs(Double(output[2 * i + 1]) - right(position)))
        }
        return worst
    }

    @Test func aSteadySignalKeepsItsLevel() {
        let interpolator = Interpolator()
        let input = [Float](repeating: 0.3, count: 400 * 2)
        // On an exact sample and between two samples: the level is the same either way.
        for start in [100.0, 100.25, 100.5, 100.75] {
            let output = render(interpolator, input, start: start, step: 1, count: 100)
            #expect(output.allSatisfy { abs($0 - 0.3) < 1e-5 })
        }
    }

    @Test func aToneReadBetweenItsSamplesIsTheSameTone() {
        let interpolator = Interpolator()
        let input = tone(frames: 400)
        for start in [100.0, 100.5, 100.3721] {
            let output = render(interpolator, input, start: start, step: 1, count: 200)
            #expect(error(output, start: start, step: 1) < 2e-5)
        }
    }

    @Test func aTonePlayedFasterOrSlowerIsStillTheSameTone() {
        let interpolator = Interpolator()
        let input = tone(frames: 400)
        // The extremes of the correction loop, 1000 ppm either way, and a plainly audible speed change.
        for step in [0.999, 1.001, 1.02, 0.98] {
            let output = render(interpolator, input, start: 100, step: step, count: 200)
            #expect(error(output, start: 100, step: step) < 2e-5)
        }
    }

    @Test func aGainChangeIsSpreadOverTheWholeBufferSoItIsNotHeardAsAClick() {
        let interpolator = Interpolator()
        let input = [Float](repeating: 1, count: 400 * 2)
        let count = 64
        let output = render(interpolator, input, start: 100, step: 1, count: count, gain: (0, 1))
        for i in 0..<count {
            #expect(abs(Double(output[2 * i]) - Double(i + 1) / Double(count)) < 1e-5)
        }
        // Coming back down lands at the gain it was given, not at the one it started from.
        let down = render(interpolator, input, start: 100, step: 1, count: count, gain: (1, 0))
        #expect(down[0] > 0.9 && abs(down[2 * (count - 1)]) < 1e-5)
    }
}
