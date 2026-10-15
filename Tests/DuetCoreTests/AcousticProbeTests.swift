import Foundation
import Testing
@testable import DuetCore

/// Hearing the calibration clicks back through the microphone, on a recording made here with a
/// known delay. This is what tells each speaker how late it is, so a wrong delay misaligns them.
struct AcousticProbeTests {
    let rate = 48_000.0
    let startTime = 1_000.0
    let probe = AcousticProbe()

    /// A second of microphone noise with clicks added at `delay` after each reference time.
    func recording(noiseLevel: Float = 0.01,
                   clicks: [(reference: Double, delay: Double, amplitude: Float)]) -> AcousticProbe.Recording {
        var state: UInt32 = 12_345
        func noise() -> Float {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return (Float(state & 0xFFFF) / 32_768 - 1) * noiseLevel
        }
        let recording = AcousticProbe.Recording(sampleRate: rate)
        recording.startTime = startTime
        recording.samples = (0..<Int(rate)).map { _ in noise() }
        let click = AcousticProbe.clickWaveform(sampleRate: rate)
        for c in clicks {
            let at = Int(((c.reference + c.delay) - startTime) * rate)
            for k in click.indices { recording.samples[at + k] += click[k] * c.amplitude }
        }
        return recording
    }

    /// Reference times inside the recording, far enough in to leave room for the search window.
    func reference(_ i: Int) -> Double { startTime + 0.1 + Double(i) * 0.3 }

    @Test func aClickIsFoundAtAboutTheDelayItWasPlayedWith() {
        let delays = [0.01, 0.05, 0.12]
        let clicks = delays.enumerated().map { (reference: reference($0.offset), delay: $0.element, amplitude: Float(0.3)) }
        let found = probe.detect(in: recording(clicks: clicks), references: delays.indices.map(reference),
                                 minDelay: -0.05, maxDelay: 0.2)
        for (i, delay) in delays.enumerated() {
            #expect(found[i].count == 1)
            // Within a millisecond: the rule picks the first edge of the click, a little before its peak.
            #expect(abs(found[i][0].delay - delay) < 1e-3)
            #expect(found[i][0].strength > 8)
        }
    }

    @Test func twoOutputsAreMeasuredAsFarApartAsTheyReallyAre() {
        // What calibration uses: not the delay itself but how much later one output is than another.
        let apart = 0.005
        let clicks = [(reference: reference(0), delay: 0.02, amplitude: Float(0.3)),
                      (reference: reference(1), delay: 0.02 + apart, amplitude: Float(0.3))]
        let found = probe.detect(in: recording(clicks: clicks), references: [reference(0), reference(1)],
                                 minDelay: -0.05, maxDelay: 0.2)
        let measured = found[1][0].delay - found[0][0].delay
        #expect(abs(measured - apart) < 2.5 / rate)   // to a sample or two, 40 microseconds
    }

    @Test func aClickTooWeakToBeHeardScoresTooLowToCount() {
        let reference = reference(0)
        let loud = probe.detect(in: recording(clicks: [(reference, 0.05, 0.3)]), references: [reference],
                                minDelay: -0.05, maxDelay: 0.2)
        #expect(loud[0][0].strength > 8)
        // The same click, now no louder than the room: heard as nothing, so calibration drops it.
        let weak = probe.detect(in: recording(clicks: [(reference, 0.05, 0.004)]), references: [reference],
                                minDelay: -0.05, maxDelay: 0.2)
        #expect(weak[0].allSatisfy { $0.strength < 8 })
    }

    @Test func theSoundStraightFromTheSpeakerIsReportedNotTheLouderEcho() {
        // A wall sends a second, stronger copy 10 ms later. The speaker's own sound is the one to time.
        let reference = reference(0)
        let found = probe.detect(in: recording(clicks: [(reference, 0.02, 0.4), (reference, 0.03, 0.6)]),
                                 references: [reference], minDelay: -0.05, maxDelay: 0.2)
        #expect(found[0].count == 1)
        #expect(abs(found[0][0].delay - 0.02) < 1e-3)
    }

    @Test func everyArrivalAskedForComesBackInTimeOrder() {
        let reference = reference(0)
        // Loudest in the middle, so order by time and order by strength are not the same.
        let found = probe.detect(in: recording(clicks: [(reference, 0.02, 0.3), (reference, 0.03, 0.5),
                                                        (reference, 0.045, 0.4)]),
                                 references: [reference], minDelay: -0.05, maxDelay: 0.2, peaks: 3)
        #expect(found[0].count == 3)
        #expect(found[0].map(\.delay) == found[0].map(\.delay).sorted())
        for (arrival, delay) in zip(found[0], [0.02, 0.03, 0.045]) {
            #expect(abs(arrival.delay - delay) < 1e-3)
            #expect(arrival.strength > 8)
        }
    }

    @Test func twoArrivalsTooCloseToTellApartCountAsOne() {
        let reference = reference(0)
        // 1 ms apart: one sound bouncing inside the speaker's own enclosure, not two arrivals.
        let found = probe.detect(in: recording(clicks: [(reference, 0.02, 0.3), (reference, 0.021, 0.3)]),
                                 references: [reference], minDelay: -0.05, maxDelay: 0.2, peaks: 3)
        #expect(found[0].count == 1)
    }

    @Test func aWindowWithNoClickInItReportsNothingHeard() {
        let reference = reference(0)
        let silent = recording(clicks: [])
        #expect(probe.detect(in: silent, references: [reference], minDelay: -0.05, maxDelay: 0.2, peaks: 3)[0].isEmpty)
        // Asked for one arrival it answers with the room's loudest moment, scored far too low to count.
        let one = probe.detect(in: silent, references: [reference], minDelay: -0.05, maxDelay: 0.2)
        #expect(one[0].allSatisfy { $0.strength < 8 })
        // A click that is there, but not inside the window asked for.
        let elsewhere = recording(clicks: [(reference, 0.19, 0.3)])
        #expect(probe.detect(in: elsewhere, references: [reference], minDelay: -0.05, maxDelay: 0.1)[0]
            .allSatisfy { $0.strength < 8 })
    }

    @Test func aWindowThatIsNotFullyInsideTheRecordingReportsNothing() {
        let recording = recording(clicks: [])
        let end = startTime + Double(recording.samples.count) / rate
        // Past the end of what was recorded.
        #expect(probe.detect(in: recording, references: [end + 1], minDelay: 0, maxDelay: 0.2)[0].isEmpty)
        // Ending inside the recording, but with less than a click left to match against.
        #expect(probe.detect(in: recording, references: [end - 0.001], minDelay: 0, maxDelay: 0.0005)[0].isEmpty)
        // Before the start of what was recorded.
        #expect(probe.detect(in: recording, references: [startTime - 1], minDelay: 0, maxDelay: 0.2)[0].isEmpty)
    }

    @Test func theClickIsAShortBurstThatStartsAndEndsInSilence() {
        let click = AcousticProbe.clickWaveform(sampleRate: rate)
        let seconds = Double(click.count) / rate
        #expect(seconds > 0.001 && seconds < 0.002)   // short enough to tell an echo from the sound
        #expect(click.first == 0)
        #expect(click.last == 0)                      // or the click would end with a click of its own
        #expect(click.map(abs).max()! > 0.9)
        // A burst of a tone high enough to time and low enough for any speaker: around 4 kHz.
        let crossings = zip(click, click.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        #expect(crossings >= 10 && crossings <= 14)
    }
}
