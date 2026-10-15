import Foundation
import Testing
@testable import EnsembleCore

/// How far ahead of the main output every other output has to read the stream. Too little and the
/// output plays frames the ring does not hold yet; too much and it is heard late.
struct OutputLeadTests {
    /// A device the system does not list, so every property it reports is the fallback: 48 kHz,
    /// no reported latency, a cycle of 512 frames.
    func device(_ id: UInt32, _ name: String) -> OutputDevice {
        OutputDevice(id: id, uid: "uid-\(id)", name: name, transport: 0)
    }

    /// One cycle of the fallback buffer size, plus the margin the engine keeps.
    var cycleAndMargin: Double { 512 / 48_000.0 + 0.005 }

    @Test func theMainOutputNeedsNoLeadBecauseEverythingFollowsIt() {
        let main = device(1, "built-in")
        #expect(Engine.lead(of: main, lag: 0, main: main) == 0)
        // Even if a lag was set on it by mistake: the main output is the reference.
        #expect(Engine.lead(of: main, lag: 0.05, main: main) == 0)
        #expect(Engine.lead(of: main, lag: -0.05, main: main) == 0)
    }

    @Test func anotherOutputReadsAheadByItsOwnCycleAndMargin() {
        let main = device(1, "built-in"), other = device(2, "speaker")
        #expect(abs(Engine.lead(of: other, lag: 0, main: main) - cycleAndMargin) < 1e-9)
    }

    @Test func anOutputHeardLateReadsThatMuchFurtherAhead() {
        let main = device(1, "built-in"), other = device(2, "speaker")
        // What calibration measures and stores: this one is heard 30 ms after its device admits.
        let lead = Engine.lead(of: other, lag: 0.03, main: main)
        #expect(abs(lead - (0.03 + cycleAndMargin)) < 1e-9)
        #expect(lead > Engine.lead(of: other, lag: 0, main: main))
    }

    @Test func anOutputHeardEarlyIsNeverAskedForFramesThatDoNotExistYet() {
        let main = device(1, "built-in"), other = device(2, "speaker")
        // A screen that reports more latency than it takes: calibration stores a negative lag.
        // Reading behind the newest frame is as far back as it can go.
        #expect(Engine.lead(of: other, lag: -0.1, main: main) == 0)
        #expect(Engine.lead(of: other, lag: -cycleAndMargin / 2, main: main) > 0)
    }
}
