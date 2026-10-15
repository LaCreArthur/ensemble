import Foundation

/// Estimates the other Mac's host clock from this Mac's: other = this + offset(this), from
/// request/answer exchanges (NTP style). Only the fastest tenth of the exchanges count, because a slow
/// exchange was held up on one leg and its offset is wrong by up to half the excess. A line through
/// them (least squares over a minute) also follows the drift between the two crystals.
struct ClockSync {
    struct Model: BitwiseCopyable {
        var time: Double    // this Mac's host seconds where `offset` applies
        var offset: Double  // other Mac's seconds minus this Mac's seconds
        var drift: Double   // change of offset per second
        func offset(at t: Double) -> Double { offset + drift * (t - time) }
    }

    private var samples: [(time: Double, offset: Double, roundTrip: Double)] = []
    private static let window = 60.0
    private(set) var model: Model?
    private(set) var minRoundTrip = 0.0

    /// t1: request sent (this Mac), t2: request received and t3: answer sent (other Mac), t4: answer received.
    mutating func add(t1: Double, t2: Double, t3: Double, t4: Double) {
        let roundTrip = (t4 - t1) - (t3 - t2)
        guard roundTrip >= 0, roundTrip < 0.5 else { return }
        let sample = (time: (t1 + t4) / 2, offset: ((t2 - t1) + (t3 - t4)) / 2, roundTrip: roundTrip)
        // A jump far beyond any delay means one clock restarted (sleep): start over.
        if let model, abs(sample.offset - model.offset(at: sample.time)) > 0.25 { reset() }
        samples.append(sample)
        samples.removeAll { $0.time < sample.time - Self.window }
        let fastest = samples.sorted { $0.roundTrip < $1.roundTrip }.prefix(max(10, samples.count / 10))
        minRoundTrip = fastest.first?.roundTrip ?? roundTrip
        let n = Double(fastest.count)
        let meanTime = fastest.reduce(0) { $0 + $1.time } / n
        let meanOffset = fastest.reduce(0) { $0 + $1.offset } / n
        var drift = 0.0
        if let first = samples.first, sample.time - first.time >= 20, fastest.count >= 10 {
            let sxx = fastest.reduce(0) { $0 + ($1.time - meanTime) * ($1.time - meanTime) }
            let sxy = fastest.reduce(0) { $0 + ($1.time - meanTime) * ($1.offset - meanOffset) }
            if sxx > 0 { drift = max(-1e-4, min(1e-4, sxy / sxx)) }
        }
        model = Model(time: meanTime, offset: meanOffset, drift: drift)
    }

    mutating func reset() {
        samples.removeAll()
        model = nil
    }
}
