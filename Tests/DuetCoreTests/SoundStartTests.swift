import Testing
@testable import DuetCore

/// The rule that lets the Mac where a sound starts take over: silence first, then 2 s of sound.
struct SoundStartTests {
    let rate = 48_000.0
    let cycle = 480   // 10 ms
    let loud: Float = 0.1

    /// Feeds `seconds` of one level; returns the times (s, from the start of this call) it reported a start.
    func feed(_ d: inout SoundStart, _ peak: Float, _ seconds: Double) -> [Double] {
        var starts: [Double] = []
        for i in 0..<Int(seconds * rate) / cycle where d.feed(peak: peak, frames: cycle) {
            starts.append(Double((i + 1) * cycle) / rate)
        }
        return starts
    }

    @Test func soundAfterSilenceStartsAfterTwoSeconds() {
        var d = SoundStart(rate: rate)
        #expect(feed(&d, 0, 1).isEmpty)
        #expect(feed(&d, loud, 3) == [2.0])
    }

    @Test func alertShorterThanTwoSecondsDoesNotStart() {
        var d = SoundStart(rate: rate)
        _ = feed(&d, 0, 1)
        #expect(feed(&d, loud, 1.9).isEmpty)
        #expect(feed(&d, 0, 1).isEmpty)
        // The next sound counts from its own beginning, not from the alert's.
        #expect(feed(&d, loud, 1.5).isEmpty)
    }

    @Test func soundAlreadyPlayingWhenWatchingBeginsNeverStarts() {
        // An app that ignored the pause and kept playing after this Mac stopped sharing.
        var d = SoundStart(rate: rate)
        #expect(feed(&d, loud, 10).isEmpty)
    }

    @Test func pausedAppPlayingZerosIsSilence() {
        var d = SoundStart(rate: rate)
        #expect(feed(&d, 0, 5).isEmpty)
        #expect(feed(&d, SoundStart.floor / 2, 5).isEmpty)
    }

    @Test func quietMusicCounts() {
        var d = SoundStart(rate: rate)
        _ = feed(&d, 0, 1)
        #expect(feed(&d, 0.001, 3) == [2.0])   // -60 dBFS
    }

    @Test func shortDipInsideASoundDoesNotRestartTheCount() {
        var d = SoundStart(rate: rate)
        _ = feed(&d, 0, 1)
        #expect(feed(&d, loud, 1.5).isEmpty)
        #expect(feed(&d, 0, 0.1).isEmpty)       // a 100 ms gap between notes
        #expect(feed(&d, loud, 1).count == 1)   // 1.5 + 0.5 s more of sound
    }

    @Test func startsOncePerSound() {
        var d = SoundStart(rate: rate)
        _ = feed(&d, 0, 1)
        #expect(feed(&d, loud, 10).count == 1)
        _ = feed(&d, 0, 1)
        #expect(feed(&d, loud, 3).count == 1)   // a new sound after silence starts again
    }

    @Test func silenceShorterThanAQuarterSecondDoesNotArm() {
        var d = SoundStart(rate: rate)
        _ = feed(&d, loud, 1)
        _ = feed(&d, 0, 0.2)
        #expect(feed(&d, loud, 3).isEmpty)
    }
}
