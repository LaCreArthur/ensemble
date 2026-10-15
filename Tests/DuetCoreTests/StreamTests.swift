import CryptoKit
import Foundation
import Testing
@testable import DuetCore

/// Receiving the other Mac's sound: packets arrive twice over two routes, out of order, late or not
/// at all, and what must come out is the sender's sound, in order, at the moment the sender says.
struct StreamTests {
    let rate = 48_000.0
    let count = StreamPacket.frames
    let id: UInt32 = 7
    /// The sender's own host time at which it hears its source frame 0. The two Macs booted at
    /// different moments, so the sender's clock reads `clockOffset` ahead of this one's.
    let heardAtFrameZero = 5_000.0
    let clockOffset = 0.5
    let receiver: StreamReceiver

    init() {
        let secret = SymmetricKey(data: Data(repeating: 3, count: 32))
        let key = Seal.derive(secret, salt: [1, 2, 3], "duet udp I>R")
        receiver = StreamReceiver(crypto: DatagramCrypto(send: key, receive: key), name: "duet-test")
        receiver.prepare(outputRate: rate, sourceRate: rate)
    }

    /// The sound the sender captured: source frame f holds (f modulo 8192) * 2e-4, so a position can
    /// be read back out of the sound, and no window read below crosses where it starts over.
    func value(_ frame: Int) -> Float { Float(frame % 8_192) * 2e-4 }

    /// Frames the band-limited reading of the sound reaches on either side of a position, so the sound
    /// just inside a gap's edge is a mix of both sides.
    let skirt = 40

    /// The sender's host time at which source frame `frame` is heard on the sender.
    func senderTime(_ frame: Int) -> Double { heardAtFrameZero + Double(frame) / rate }

    /// This Mac's host time for that same moment, which is what an output here is given.
    func localTime(_ frame: Int) -> Double { senderTime(frame) - clockOffset }

    /// Teaches the receiver how far the other Mac's clock is ahead of this one's, through the
    /// request and answer exchanges it learns that from.
    func exchangeClocks(from: Double = 4_990) {
        for k in 0..<20 {
            let t1 = from + Double(k) * 0.02, arrived = t1 + 0.001
            var answer = ByteWriter()
            answer.put(t1)                                  // sent, this Mac's clock
            answer.put(arrived + clockOffset)               // received, the other Mac's clock
            answer.put(arrived + 0.0002 + clockOffset)      // answered, the other Mac's clock
            receiver.handle(StreamPacket.clockAnswer, answer.bytes, arrival: arrived + 0.0012)
        }
    }

    /// Delivers audio packet `index` (source frames index * 240 upwards), as a route would.
    func deliver(_ index: Int, stream: UInt32? = nil, gain: Float = 1, arrival: Double? = nil,
                 sound: ((Int) -> Float)? = nil) {
        let frame = index * count
        var payload = ByteWriter()
        payload.put(stream ?? id)
        payload.put(Int64(frame))
        payload.put(senderTime(frame))
        payload.put(gain)
        payload.put(Float(rate))
        for i in 0..<(count * 2) {
            let x = (sound ?? value)(frame + i / 2)
            let scaled = (x / StreamPacket.headroom * 32767).rounded()
            payload.put(Int16(max(-32768, min(32767, scaled))))
        }
        receiver.handle(StreamPacket.audio, payload.bytes, arrival: arrival ?? senderTime(frame))
    }

    /// Plays `frames` output frames, the first of them to be heard at this Mac's host time `at`.
    func play(at: Double, frames: Int = 480) -> [Float] {
        var output = [Float](repeating: .nan, count: frames * 2)
        output.withUnsafeMutableBufferPointer { receiver.render(frames: frames, heardAt: at, into: $0.baseAddress!) }
        return output
    }

    /// Plays the cycle before `at` first, so the measured cycle is one of a stream already playing:
    /// a stream's very first cycle fades its gain in, which a position cannot be read through.
    func playWhileRunning(at: Double, frames: Int = 480) -> [Float] {
        _ = play(at: at - Double(frames) / rate, frames: frames)
        return play(at: at, frames: frames)
    }

    /// The source position the sound at output frame `i` was taken from.
    func position(_ output: [Float], _ i: Int) -> Double { Double(output[2 * i]) / 2e-4 }

    @Test func theSoundPlaysAtTheMomentTheSenderSaysItIsHeard() {
        exchangeClocks()
        for index in 0..<20 { deliver(index) }
        // Asking for the sound to be heard at the moment the sender hears its frame 1000.
        let first = play(at: localTime(1_000))
        #expect(abs(position(first, 479) - 1_479) < 1)
        // The next output cycle carries straight on from there.
        let next = play(at: localTime(1_480))
        #expect(abs(position(next, 0) - 1_480) < 1)
        #expect(abs(position(next, 479) - 1_959) < 1)
        let stats = receiver.takeStats()
        #expect(stats.packets == 20)
        #expect(stats.concealed == 0)
        // The sound was there well before it was needed: 20 packets in, playing packet 8.
        #expect(stats.minMargin > 0.05 && stats.minMargin < 0.07)
        #expect(abs(stats.error) < 1e-9)
    }

    @Test func nothingPlaysUntilTheSendersClockIsKnown() {
        for index in 0..<20 { deliver(index) }
        #expect(play(at: localTime(1_000)).allSatisfy { $0 == 0 })
        exchangeClocks()
        deliver(20)
        #expect(play(at: localTime(1_000)).contains { $0 != 0 })
        // And nothing plays for an output that cannot say when its frames will be heard.
        var output = [Float](repeating: 1, count: 960)
        output.withUnsafeMutableBufferPointer { receiver.render(frames: 480, heardAt: nil, into: $0.baseAddress!) }
        #expect(output.allSatisfy { $0 == 0 })
    }

    @Test func aPacketThatCameTwiceOverTheTwoRoutesIsKeptOnce() {
        exchangeClocks()
        for index in 0..<10 { deliver(index) }
        for index in 0..<10 { deliver(index) }   // the same packets again, from the slower route
        let stats = receiver.takeStats()
        #expect(stats.packets == 10)
        #expect(stats.resent == 0)               // a second copy is not a recovered loss
        let output = play(at: localTime(1_000))
        #expect(abs(position(output, 479) - 1_479) < 1)
    }

    @Test func packetsThatArrivedOutOfOrderPlayInOrder() {
        exchangeClocks()
        for index in [0, 2, 1, 4, 3, 5, 7, 6, 8, 9] { deliver(index) }
        // The sound across the packets that swapped places is whole, in source order.
        let output = playWhileRunning(at: localTime(960))
        for i in stride(from: 0, to: 480, by: 48) {
            #expect(abs(position(output, i) - Double(960 + i)) < 1)
        }
    }

    @Test func aPacketThatNeverArrivedIsPlayedAsSilenceNotAsOldSound() {
        exchangeClocks()
        for index in [0, 1, 3, 4, 5] { deliver(index) }   // packet 2 is lost
        let output = playWhileRunning(at: localTime(2 * count))
        #expect(output[(skirt * 2)..<((count - skirt) * 2)].allSatisfy { $0 == 0 })
        let stats = receiver.takeStats()
        #expect(stats.concealed > 0)
        // The sound that did arrive still plays: frames after the gap are the sender's.
        #expect(abs(position(output, count + skirt) - Double(3 * count + skirt)) < 1)
    }

    @Test func aPacketMissingAfterTheStoreWrappedRoundIsSilenceNotTheSoundFromBefore() {
        exchangeClocks()
        // Packet 2 arrives, then the stream runs on until its slot comes round again 512 packets later.
        deliver(2)
        for index in [510, 511, 512, 513, 515, 516] { deliver(index) }
        // The packets that did arrive after the store wrapped round play as the sender's sound.
        let after = playWhileRunning(at: localTime(512 * count))
        #expect(abs(position(after, skirt) - Double((512 * count + skirt) % 8_192)) < 1)
        // Packet 514 shares packet 2's place in the store, and never came.
        let output = playWhileRunning(at: localTime(514 * count))
        #expect(output[(skirt * 2)..<((count - skirt) * 2)].allSatisfy { $0 == 0 })
    }

    @Test func aLatePacketFillsItsGapAndIsCountedAsRecovered() {
        exchangeClocks()
        deliver(0)
        deliver(2)          // packet 1 is now known to be missing, and is asked for again
        deliver(1)          // the answer to that request
        for index in 3..<6 { deliver(index) }
        let stats = receiver.takeStats()
        #expect(stats.packets == 6)
        #expect(stats.resent == 1)
        // And because it arrived before it was needed, its sound plays and nothing is concealed.
        let output = playWhileRunning(at: localTime(3 * count))
        #expect(abs(position(output, 10) - Double(3 * count + 10)) < 1)
        #expect(receiver.takeStats().concealed == 0)
    }

    @Test func soundLouderThanFullScaleSurvivesTheTripAtItsOwnLevel() {
        exchangeClocks()
        // A float stream can go past 1: the sender halves it to fit 16 bits and the receiver doubles back.
        for index in 0..<10 { deliver(index, sound: { _ in 1.6 }) }
        let output = play(at: localTime(1_000))
        #expect(abs(output[2 * 479] - 1.6) < 0.01)
        #expect(abs(output[2 * 479 + 1] - 1.6) < 0.01)
    }

    @Test func theSenderCanSilenceTheOtherMacWhileThisOneTunes() {
        exchangeClocks()
        for index in 0..<10 { deliver(index, gain: 0) }
        #expect(play(at: localTime(1_000)).allSatisfy { $0 == 0 })
        for index in 10..<20 { deliver(index, gain: 1) }
        let output = play(at: localTime(2_900))
        #expect(abs(position(output, 479) - 3_379) < 1)
    }

    @Test func aStreamFromAMacThatRestartedLeavesNoneOfTheOldOneBehind() {
        exchangeClocks()
        for index in 0..<5 { deliver(index) }
        // The sender restarted: a new stream, whose first packet takes the old packet 0's place.
        deliver(0, stream: id + 1)
        // The places the old stream filled must not play as the new stream's sound.
        let output = play(at: localTime(count))
        #expect(output[(skirt * 2)..<(count * 2)].allSatisfy { $0 == 0 })
    }

    @Test func aPacketFarTooOldToPlayIsDropped() {
        exchangeClocks()
        deliver(0)
        deliver(1_000)
        let before = receiver.takeStats().packets
        #expect(before == 2)
        deliver(100)        // from 900 packets ago: its place has been reused since
        #expect(receiver.takeStats().packets == 2)
        deliver(900)        // recent enough to still be worth keeping
        #expect(receiver.takeStats().packets == 3)
    }

    @Test func aPacketWhoseFrameIsNotWhereAPacketStartsIsIgnored() {
        exchangeClocks()
        var payload = ByteWriter()
        payload.put(id)
        payload.put(Int64(count * 3 + 7))   // not a packet boundary, so nothing can be made of it
        payload.put(senderTime(count * 3 + 7))
        payload.put(Float(1))
        payload.put(Float(rate))
        for _ in 0..<(count * 2) { payload.put(Int16(1_000)) }
        receiver.handle(StreamPacket.audio, payload.bytes, arrival: senderTime(count * 3 + 7))
        #expect(receiver.takeStats().packets == 0)
    }

    @Test func aTruncatedPacketIsIgnoredRatherThanPlayedAsNoise() {
        exchangeClocks()
        for index in 0..<10 { deliver(index) }
        var payload = ByteWriter()
        payload.put(id)
        payload.put(Int64(10 * count))
        payload.put(senderTime(10 * count))
        payload.put(Float(1))
        receiver.handle(StreamPacket.audio, payload.bytes, arrival: senderTime(10 * count))
        #expect(receiver.takeStats().packets == 10)
    }
}
