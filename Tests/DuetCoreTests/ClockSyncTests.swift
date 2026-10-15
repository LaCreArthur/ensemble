import Foundation
import Testing
@testable import DuetCore

/// Learning the other Mac's clock from request and answer times: the whole sync rests on it, so a
/// wrong offset means the two Macs play the same sound at different moments.
struct ClockSyncTests {
    /// One exchange at this Mac's time `time`: `delay` seconds each way, plus `extra` on the way out
    /// only (a leg held up in a queue), with the other Mac's clock ahead by `offset`.
    func exchange(_ sync: inout ClockSync, at time: Double, offset: Double, delay: Double, extra: Double = 0) {
        let processing = 0.0007
        let arrived = time + delay + extra
        sync.add(t1: time, t2: arrived + offset, t3: arrived + processing + offset,
                 t4: arrived + processing + delay)
    }

    /// `count` exchanges, `step` seconds apart, starting at `from`.
    func feed(_ sync: inout ClockSync, count: Int, from: Double = 1_000, step: Double = 0.02,
              offset: (Double) -> Double, delay: (Int) -> Double = { _ in 0.005 }) {
        for k in 0..<count {
            let time = from + Double(k) * step
            exchange(&sync, at: time, offset: offset(time), delay: delay(k))
        }
    }

    @Test func theOtherMacsClockIsRecoveredFromTheExchanges() {
        var sync = ClockSync()
        feed(&sync, count: 50, offset: { _ in 0.25 })
        let model = sync.model
        #expect(model != nil)
        #expect(abs(model!.offset - 0.25) < 1e-9)
        #expect(abs(sync.minRoundTrip - 0.010) < 1e-9)   // the two legs, not the other Mac's own delay
        #expect(model!.drift == 0)                       // too little time to claim a drift
        // And so the other Mac's clock can be read at any moment of this Mac's.
        #expect(abs(model!.offset(at: model!.time + 5) - 0.25) < 1e-9)
    }

    @Test func anExchangeHeldUpOnOneLegDoesNotMoveTheEstimate() {
        var sync = ClockSync()
        feed(&sync, count: 30, offset: { _ in 0.25 })
        // Many exchanges held up 80 ms on the way out: each says the clock is 40 ms off, and it is not.
        for k in 0..<300 {
            exchange(&sync, at: 1_000.6 + Double(k) * 0.02, offset: 0.25, delay: 0.005, extra: 0.08)
        }
        // Each of those says 0.29; the estimate stays an order of magnitude closer than that.
        #expect(abs(sync.model!.offset - 0.25) < 0.005)
        #expect(abs(sync.minRoundTrip - 0.010) < 1e-9)
    }

    @Test func anImpossiblyFastExchangeIsIgnored() {
        var sync = ClockSync()
        feed(&sync, count: 20, offset: { _ in 0.25 })
        // The answer appears to have come back before the request left: a clock moved under us.
        sync.add(t1: 2_000, t2: 2_000.3, t3: 2_000.3, t4: 1_999.9)
        #expect(sync.minRoundTrip > 0)
        #expect(abs(sync.model!.offset - 0.25) < 1e-9)
    }

    @Test func exchangesFarTooSlowToMeanAnythingAreIgnored() {
        var sync = ClockSync()
        feed(&sync, count: 20, offset: { _ in 0.25 })
        // 5 s round trips: whatever held them up is larger than anything they could measure.
        for k in 0..<200 {
            exchange(&sync, at: 1_000.5 + Double(k) * 0.02, offset: 0.25, delay: 0.005, extra: 5)
        }
        #expect(abs(sync.model!.offset - 0.25) < 1e-9)
    }

    @Test func theDriftBetweenTheTwoCrystalsIsFollowed() {
        var sync = ClockSync()
        let start = 1_000.0, drift = 20e-6    // 20 ppm, the kind of difference two Macs have
        feed(&sync, count: 600, from: start, step: 0.1,
             offset: { 0.25 + drift * ($0 - start) },
             delay: { 0.005 + 0.0001 * Double($0 % 10) })
        let model = sync.model!
        #expect(abs(model.drift - drift) < 1e-6)
        // Which is what makes the clock readable a few seconds ahead, between two exchanges.
        #expect(abs(model.offset(at: start + 70) - (0.25 + drift * 70)) < 2e-5)
    }

    @Test func aDriftIsNotGuessedFromTooShortAWindow() {
        var sync = ClockSync()
        let start = 1_000.0, drift = 20e-6
        // 10 s of exchanges: the drift over it is smaller than the spread of the measurements.
        feed(&sync, count: 100, from: start, step: 0.1,
             offset: { 0.25 + drift * ($0 - start) },
             delay: { 0.005 + 0.0001 * Double($0 % 10) })
        #expect(sync.model!.drift == 0)
    }

    @Test func anAbsurdDriftIsCappedInsteadOfRunningAway() {
        var sync = ClockSync()
        let start = 1_000.0
        // 2000 ppm: no pair of crystals differs that much, so it is bad data, not a drift.
        feed(&sync, count: 600, from: start, step: 0.1,
             offset: { 0.25 + 2e-3 * ($0 - start) },
             delay: { 0.005 + 0.0001 * Double($0 % 10) })
        #expect(sync.model!.drift == 1e-4)
    }

    @Test func aClockThatRestartedStartsTheEstimateOver() {
        var sync = ClockSync()
        feed(&sync, count: 30, offset: { _ in 0.25 })
        #expect(abs(sync.model!.offset - 0.25) < 1e-9)
        // The other Mac slept: its clock is now a second away. Averaging across that is wrong.
        // The new exchanges are a little slower, so the old ones would win if they were kept.
        for k in 0..<30 {
            exchange(&sync, at: 1_001 + Double(k) * 0.02, offset: 1.25, delay: 0.006)
        }
        #expect(abs(sync.model!.offset - 1.25) < 1e-9)
        #expect(abs(sync.minRoundTrip - 0.012) < 1e-9)
    }

    @Test func startingOverLeavesNothingBehind() {
        var sync = ClockSync()
        feed(&sync, count: 30, offset: { _ in 0.25 })
        sync.reset()
        #expect(sync.model == nil)
        feed(&sync, count: 30, from: 2_000, offset: { _ in 0.9 })
        #expect(abs(sync.model!.offset - 0.9) < 1e-9)
        #expect(sync.model!.drift == 0)
    }

    @Test func theEstimateFollowsTheDriftItSeesNowNotTheWholeHistory() {
        var sync = ClockSync()
        let start = 1_000.0
        let delay: (Int) -> Double = { 0.005 + 0.0001 * Double($0 % 10) }
        // A minute drifting one way, then a minute drifting the other (a Mac that warmed up).
        feed(&sync, count: 600, from: start, step: 0.1,
             offset: { 0.25 + 20e-6 * ($0 - start) }, delay: delay)
        #expect(sync.model!.drift > 1e-5)
        let turn = start + 60
        feed(&sync, count: 600, from: turn, step: 0.1,
             offset: { 0.25 + 20e-6 * 60 - 20e-6 * ($0 - turn) }, delay: delay)
        #expect(sync.model!.drift < -1e-5)
    }
}
