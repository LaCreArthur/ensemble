import Foundation
import Testing
@testable import EnsembleCore

/// Playing a sound for an output that runs on its own clock: it must play the position the caller
/// asks for, slide into place slowly enough that no pitch change is heard, and jump only when the
/// distance is too large to slide.
struct PlayheadTests {
    let rate = 48_000.0
    let frames = 480            // a 10 ms output cycle
    let sourceFrames = 48_000 * 8

    /// Source frame f holds f / 1000 in both channels, so a position can be read back from the sound.
    func sourceValue(_ frame: Double) -> Double { frame / 1000 }

    /// A fetch over a source holding frames 0..<sourceFrames; anything outside is reported missing.
    func fetch(_ first: Int, _ count: Int, _ into: UnsafeMutablePointer<Float>) -> Int {
        var missing = 0
        for i in 0..<count {
            let frame = first + i
            let inside = frame >= 0 && frame < sourceFrames
            if !inside { missing += 1 }
            let value = inside ? Float(sourceValue(Double(frame))) : 0
            into[2 * i] = value
            into[2 * i + 1] = value
        }
        return missing
    }

    struct Cycle {
        var jumped: Bool
        /// Playback position minus the target, seconds, as the cycle reported it.
        var error: Double
        /// The source position the cycle started playing from, from its own report.
        var position: Double
        /// The source position its sound was actually taken from, read back out of the sound itself.
        var heard: Double
        var missing: Int
    }

    /// Plays `cycles` output cycles, the target given by `target(cycle)`, and reports each cycle.
    func play(_ playhead: Playhead, cycles: Int, target: (Int) -> Double) -> [Cycle] {
        var output = [Float](repeating: 0, count: frames * 2)
        var history: [Cycle] = []
        for k in 0..<cycles {
            let t = target(k)
            let result = output.withUnsafeMutableBufferPointer { out in
                playhead.render(target: t, rate: rate, nominal: 1, frames: frames, gain: 1,
                                into: out.baseAddress!, fetch: fetch)
            }
            guard let result else { break }
            // The last frame of the cycle, where the gain ramp has reached full.
            let heard = Double(output[2 * (frames - 1)]) * 1000 - Double(frames - 1)
            history.append(Cycle(jumped: result.jumped, error: result.error, position: t - result.error * rate,
                                 heard: heard, missing: result.missing))
        }
        return history
    }

    /// A target that advances one source frame per output frame from `start`.
    func steady(from start: Double) -> (Int) -> Double { { start + Double($0 * self.frames) } }

    @Test func theFirstCyclePlaysExactlyTheFrameItWasAskedFor() {
        let playhead = Playhead(ratio: 1)
        let history = play(playhead, cycles: 1, target: steady(from: 20_000))
        #expect(history[0].jumped)
        #expect(history[0].error == 0)
        #expect(abs(history[0].heard - 20_000) < 1)   // within a frame of it
    }

    @Test func everyCyclePlaysTheSoundFromThePositionItReports() {
        let playhead = Playhead(ratio: 1)
        let history = play(playhead, cycles: 100, target: steady(from: 20_000))
        #expect(history.count == 100)
        #expect(history.allSatisfy { abs($0.heard - $0.position) < 1 })
        // Steady target, so it plays straight on: one source frame per output frame.
        #expect(abs(history.last!.position - (20_000 + Double(99 * frames))) < 1)
    }

    @Test func aPositionFarFromTheTargetJumpsThereInsteadOfSliding() {
        let playhead = Playhead(ratio: 1)
        var history = play(playhead, cycles: 100, target: steady(from: 20_000))
        #expect(history.dropFirst().allSatisfy { !$0.jumped })
        // Now the sound to play moves 50 ms: too far to slide, so it jumps and is there at once.
        let base = 20_000 + Double(100 * frames) + 0.05 * rate
        history = play(playhead, cycles: 3, target: steady(from: base))
        #expect(history[0].jumped)
        #expect(abs(history[0].heard - base) < 1)         // the new place, this cycle, not over 4 s
        #expect(!history[1].jumped)
        #expect(abs(history[1].error) < 1e-9)
    }

    @Test func aPositionJustOffTheTargetSlidesIntoPlaceWithoutAJump() {
        let playhead = Playhead(ratio: 1)
        _ = play(playhead, cycles: 100, target: steady(from: 20_000))
        // 2 ms late, the kind of error a drifting clock leaves: slide, never jump.
        let base = 20_000 + Double(100 * frames) + 0.002 * rate
        let history = play(playhead, cycles: 600, target: steady(from: base))   // 6 s
        #expect(history.allSatisfy { !$0.jumped })
        #expect(abs(history[0].error - 0.002) < 1e-9)
        #expect(abs(history[100].error) < 0.002)                // closing after 1 s
        #expect(abs(history[400].error) < 2e-4)                 // in place after 4 s
        #expect(abs(history[599].error) < 3e-4)                 // and it stays there
        // Running past the target is a wobble: it must stay far smaller than the error it started from.
        #expect(history.allSatisfy { $0.error > -4e-4 })
    }

    @Test func theSlideIsTooSlowToBeHeardAsAPitchChange() {
        let playhead = Playhead(ratio: 1)
        _ = play(playhead, cycles: 100, target: steady(from: 20_000))
        // 9 ms off, just inside the jump threshold: the longest slide the loop ever has to make.
        let base = 20_000 + Double(100 * frames) + 0.009 * rate
        let history = play(playhead, cycles: 1_000, target: steady(from: base))
        #expect(history.allSatisfy { !$0.jumped })
        #expect(abs(history.last!.error) < 1e-3)   // 9 ms absorbed within 10 s
        // Source frames read per output frame, cycle by cycle: never more than 1000 ppm from nominal.
        var worst = 0.0
        for (a, b) in zip(history, history.dropFirst()) {
            worst = max(worst, abs((b.position - a.position) / Double(frames) - 1))
        }
        #expect(worst > 1e-4)            // it does correct
        #expect(worst <= 1.000001e-3)    // and never faster than 1000 ppm
    }

    @Test func framesTheFetchCannotGiveAreReportedSoTheGapCanBeConcealed() {
        let playhead = Playhead(ratio: 1)
        // A target before the start of the source: those frames do not exist.
        let history = play(playhead, cycles: 1, target: steady(from: -1_000))
        #expect(history[0].missing > 0)
        let inside = play(playhead, cycles: 1, target: steady(from: 20_000))
        #expect(inside[0].missing == 0)
    }

    @Test func aSpanTooLongToReadPlaysSilenceAndStartsAgainAtTheNextTarget() {
        let playhead = Playhead(ratio: 1)
        // A long cycle still plays, as long as the frames it needs fit in one read.
        var long = [Float](repeating: 0, count: 19_000 * 2)
        let fits = long.withUnsafeMutableBufferPointer { out in
            playhead.render(target: 20_000, rate: rate, nominal: 1, frames: 19_000, gain: 1,
                            into: out.baseAddress!, fetch: fetch)
        }
        #expect(fits != nil)
        #expect(abs(Double(long[2 * 18_999]) * 1000 - (20_000 + 18_999)) < 1)
        // Longer than that, it plays silence rather than the wrong sound.
        var output = [Float](repeating: 1, count: 30_000 * 2)
        let result = output.withUnsafeMutableBufferPointer { out in
            playhead.render(target: 40_000, rate: rate, nominal: 1, frames: 30_000, gain: 1,
                            into: out.baseAddress!, fetch: fetch)
        }
        #expect(result == nil)
        #expect(output.allSatisfy { $0 == 0 })
        // Having given up, it starts again at the next target rather than sliding from a position
        // it never played, even when that position is near enough to slide from.
        let next = play(playhead, cycles: 1, target: steady(from: 40_100))
        #expect(next[0].jumped)
        #expect(abs(next[0].heard - 40_100) < 1)
    }

    @Test func aJumpStartsTheCorrectionAgainSoTheSoundDoesNotKeepDrifting() {
        let playhead = Playhead(ratio: 1)
        // A long sustained error winds the correction loop up.
        _ = play(playhead, cycles: 1, target: steady(from: 20_000))
        var next = 20_000 + Double(frames)
        _ = play(playhead, cycles: 400, target: { _ in
            let t = next + 0.009 * self.rate
            next += Double(self.frames)
            return t
        })
        // Then the sound to play moves far enough to jump. What the loop had wound up no longer applies.
        let base = next + 0.05 * rate
        let history = play(playhead, cycles: 200, target: steady(from: base))
        #expect(history[0].jumped)
        #expect(history.dropFirst().allSatisfy { !$0.jumped })
        #expect(abs(history.last!.error) < 2e-4)   // 2 s later it is still in place
    }

    @Test func theSameCorrectionTakesTheSameTimeWhateverTheOutputsBufferSize() {
        // A device asking for 50 ms at a time must settle like one asking for 10 ms.
        var trajectories: [[Double]] = []
        for cycle in [480, 2_400] {
            let playhead = Playhead(ratio: 1)
            var output = [Float](repeating: 0, count: cycle * 2)
            let perSecond = Int(rate) / cycle
            var errors: [Double] = []
            for k in 0..<(perSecond * 7) {
                let late = k < perSecond ? 0.0 : 0.002 * rate   // settled, then 2 ms late
                let target = 20_000 + Double(k * cycle) + late
                let result = output.withUnsafeMutableBufferPointer { out in
                    playhead.render(target: target, rate: rate, nominal: 1, frames: cycle, gain: 1,
                                    into: out.baseAddress!, fetch: fetch)
                }
                errors.append(result!.error)
            }
            trajectories.append((1...6).map { errors[$0 * perSecond] })
        }
        for (small, large) in zip(trajectories[0], trajectories[1]) {
            #expect(abs(small - large) < 5e-5)
        }
    }

    @Test func startingAgainMakesTheNextCycleJumpToTheTarget() {
        let playhead = Playhead(ratio: 1)
        _ = play(playhead, cycles: 100, target: steady(from: 20_000))
        playhead.reset()
        let history = play(playhead, cycles: 2, target: steady(from: 20_000 + Double(100 * frames)))
        #expect(history[0].jumped)
        #expect(history[0].error == 0)
        #expect(!history[1].jumped)
    }
}
