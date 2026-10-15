import Foundation

/// Band-limited interpolation of a stereo signal at any fractional position: a Kaiser-windowed sinc
/// stored as a polyphase table, linearly interpolated between phases. Flat to about 20 kHz at 48 kHz,
/// so playing a stream a little faster or slower (clock drift) changes nothing audible.
final class Interpolator: @unchecked Sendable {
    /// Taps on each side of the position: the signal is needed from `half - 1` frames before to `half` after.
    static let half = 32
    private static let phases = 512
    private let taps = 2 * Interpolator.half
    private let table: UnsafeMutablePointer<Float>   // (phases + 1) rows of `taps` coefficients

    /// `ratio`: input frames per output frame (above 1 lowers the cutoff to avoid aliasing).
    init(ratio: Double = 1, beta: Double = 9) {
        let half = Self.half, taps = 2 * half, phases = Self.phases
        let cutoff = 0.47 / max(1, ratio)   // cycles per input frame
        table = .allocate(capacity: (phases + 1) * taps)
        let i0beta = Self.besselI0(beta)
        for phase in 0...phases {
            let fraction = Double(phase) / Double(phases)
            var row = [Double](repeating: 0, count: taps)
            for k in 0..<taps {
                // Distance from the position to input frame floor(position) - half + 1 + k.
                let t = Double(k - half + 1) - fraction
                let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
                let x = t / Double(half)
                let window = abs(x) >= 1 ? 0 : Self.besselI0(beta * (1 - x * x).squareRoot()) / i0beta
                row[k] = sinc * window
            }
            let sum = row.reduce(0, +)
            for k in 0..<taps { table[phase * taps + k] = Float(row[k] / sum) }
        }
    }

    deinit { table.deallocate() }

    /// Writes `count` stereo frames to `output` (interleaved), output frame i taken at input position
    /// `start + i * step`. `input` is interleaved stereo; its frame 0 is input position `inputStart`,
    /// and it must cover every position from `start - half + 1` to `start + (count - 1) * step + half`.
    func render(input: UnsafePointer<Float>, inputStart: Int, start: Double, step: Double,
                count: Int, gain: (Float, Float), into output: UnsafeMutablePointer<Float>) {
        let half = Self.half, taps = self.taps
        let gainStep = (gain.1 - gain.0) / Float(max(1, count))
        var g = gain.0
        for i in 0..<count {
            let position = start + Double(i) * step
            let whole = position.rounded(.down)
            let scaled = (position - whole) * Double(Self.phases)
            let phase = Int(scaled)
            let alpha = Float(scaled - Double(phase))
            let c0 = table + phase * taps
            let c1 = c0 + taps
            let first = (Int(whole) - half + 1 - inputStart) * 2
            var left: Float = 0, right: Float = 0
            for k in 0..<taps {
                let c = c0[k] + alpha * (c1[k] - c0[k])
                left += c * input[first + 2 * k]
                right += c * input[first + 2 * k + 1]
            }
            g += gainStep
            output[2 * i] = left * g
            output[2 * i + 1] = right * g
        }
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0, k = 1.0
        while term > 1e-12 * sum {
            term *= (x / (2 * k)) * (x / (2 * k))
            sum += term
            k += 1
        }
        return sum
    }
}
