import Testing
@testable import DuetCore

/// The ring the captured sound passes through: every output and the other Mac's stream read from it,
/// so a frame must come back exactly as captured, past the ring's end, or not at all.
struct FrameRingTests {
    /// Distinct value per frame and channel, so a frame read at the wrong place is visible.
    func value(_ frame: Int, _ channel: Int) -> Float { Float(frame) + (channel == 1 ? 0.5 : 0) }

    func write(_ ring: FrameRing, from first: Int, frames: Int) {
        var source = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            source[2 * i] = value(first + i, 0)
            source[2 * i + 1] = value(first + i, 1)
        }
        source.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames) }
    }

    /// The frames read at `index`, or nil if the ring refused the read.
    func read(_ ring: FrameRing, at index: Int, frames: Int) -> [Float]? {
        var destination = [Float](repeating: .nan, count: frames * 2)
        let ok = destination.withUnsafeMutableBufferPointer { ring.read(at: index, frames: frames, into: $0.baseAddress!) }
        return ok ? destination : nil
    }

    func expected(from first: Int, frames: Int) -> [Float] {
        (0..<(frames * 2)).map { value(first + $0 / 2, $0 % 2) }
    }

    @Test func capturedFramesComeBackExactly() {
        let ring = FrameRing(capacityFrames: 1024)
        write(ring, from: 0, frames: 300)
        #expect(ring.writeIndex == 300)
        #expect(read(ring, at: 0, frames: 300) == expected(from: 0, frames: 300))
        #expect(read(ring, at: 100, frames: 50) == expected(from: 100, frames: 50))
    }

    @Test func framesStayCorrectPastTheRingsEnd() {
        let ring = FrameRing(capacityFrames: 1024)
        #expect(ring.capacity == 1024)
        // Three laps of the ring, in cycles that do not divide it.
        for i in 0..<10 { write(ring, from: i * 300, frames: 300) }
        #expect(ring.writeIndex == 3000)
        // Everything still in the ring reads back, including the frames written across its end.
        #expect(read(ring, at: 2000, frames: 1000) == expected(from: 2000, frames: 1000))
        #expect(read(ring, at: 1976, frames: 1024) == expected(from: 1976, frames: 1024))
    }

    @Test func aReadAcrossTheRingsEndJoinsBothHalves() {
        let ring = FrameRing(capacityFrames: 16)
        write(ring, from: 0, frames: 14)
        write(ring, from: 14, frames: 8)   // frames 16...21 land at the ring's start
        #expect(read(ring, at: 12, frames: 10) == expected(from: 12, frames: 10))
    }

    @Test func framesNotYetCapturedCannotBeRead() {
        let ring = FrameRing(capacityFrames: 1024)
        write(ring, from: 0, frames: 100)
        #expect(read(ring, at: 100, frames: 1) == nil)      // the very next frame
        #expect(read(ring, at: 95, frames: 10) == nil)      // a span that runs past the newest frame
        #expect(read(ring, at: 90, frames: 10) != nil)      // ends exactly on the newest frame
        #expect(read(ring, at: -1, frames: 10) == nil)
    }

    @Test func framesTheCaptureOverwroteCannotBeRead() {
        let ring = FrameRing(capacityFrames: 1024)
        write(ring, from: 0, frames: 1500)
        // Only the newest 1024 frames are still there: 476...1499.
        #expect(read(ring, at: 476, frames: 1024) != nil)
        #expect(read(ring, at: 475, frames: 1025) == nil)
        #expect(read(ring, at: 475, frames: 100) == nil)
        #expect(read(ring, at: 0, frames: 100) == nil)
    }

    @Test func silenceCountsAsCapturedFrames() {
        let ring = FrameRing(capacityFrames: 1024)
        write(ring, from: 0, frames: 10)
        ring.writeSilence(frames: 20)
        write(ring, from: 30, frames: 10)
        #expect(ring.writeIndex == 40)
        #expect(read(ring, at: 10, frames: 20) == [Float](repeating: 0, count: 40))
        #expect(read(ring, at: 30, frames: 10) == expected(from: 30, frames: 10))
    }

    @Test func silenceAcrossTheRingsEndIsSilentEverywhere() {
        let ring = FrameRing(capacityFrames: 16)
        write(ring, from: 0, frames: 16)    // one full lap, so no place in the ring is still untouched
        write(ring, from: 16, frames: 6)
        ring.writeSilence(frames: 8)        // crosses the ring's end
        #expect(read(ring, at: 22, frames: 8) == [Float](repeating: 0, count: 16))
    }
}
