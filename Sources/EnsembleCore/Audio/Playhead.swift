import Foundation

/// Plays a source for an output that runs on its own clock: each cycle the caller gives the source
/// position that must be heard first, and the playhead follows it within +-1000 ppm (a PI loop on the
/// position error, about 4 s to settle, no pitch change heard), jumping when it is more than 10 ms away.
/// Used for the other Mac's stream and for every output of this Mac but the main one.
final class Playhead: @unchecked Sendable {
    struct Result {
        /// The position was reset to the target (start, or an error beyond 10 ms).
        var jumped: Bool
        /// Playback position minus the target, seconds.
        var error: Double
        /// Last source frame read.
        var last: Int
        /// Source frames the fetch could not give (played as silence).
        var missing: Int
    }

    private let interpolator: Interpolator
    private let input: UnsafeMutablePointer<Float>
    private static let inputCapacity = 20_000
    private var position: Double?
    private var integral = 0.0
    private var lastGain: Float = 0

    /// `ratio`: source frames per output frame, nominal.
    init(ratio: Double) {
        interpolator = Interpolator(ratio: ratio)
        input = .allocate(capacity: Self.inputCapacity * 2)
    }

    deinit { input.deallocate() }

    /// Starts again at the next target, without following from the current position.
    func reset() { position = nil }

    /// Writes `frames` interleaved stereo frames to `output`, the first one at source position `target`.
    /// `rate`: source frames per second; `nominal`: source frames per output frame. `fetch(first, count, into)`
    /// copies source frames [first, first + count) and returns how many of them it could not give.
    /// Returns nil, after writing silence, if the span is too long to read.
    func render(target: Double, rate: Double, nominal: Double, frames: Int, gain: Float, into output: UnsafeMutablePointer<Float>,
                fetch: (Int, Int, UnsafeMutablePointer<Float>) -> Int) -> Result? {
        let jumped = position == nil || abs(target - position!) > 0.01 * rate
        if jumped {
            position = target
            integral = 0
        }
        let error = (target - position!) / rate
        let dt = Double(frames) * nominal / rate
        integral = max(-5e-4, min(5e-4, integral + 0.0625 * error * dt))
        let correction = max(-1e-3, min(1e-3, 0.5 * error + integral))
        let step = nominal * (1 + correction)

        let half = Interpolator.half
        let first = Int(position!.rounded(.down)) - half + 1
        let last = Int((position! + Double(frames - 1) * step).rounded(.down)) + half
        let span = last - first + 1
        guard span <= Self.inputCapacity else {
            output.update(repeating: 0, count: frames * 2)
            position = nil
            return nil
        }
        let missing = fetch(first, span, input)
        interpolator.render(input: input, inputStart: first, start: position!, step: step, count: frames,
                            gain: (lastGain, gain), into: output)
        lastGain = gain
        position! += Double(frames) * step
        return Result(jumped: jumped, error: error, last: last, missing: missing)
    }
}
