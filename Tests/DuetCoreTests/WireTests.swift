import CryptoKit
import Foundation
import Testing
@testable import DuetCore

/// The datagrams between the two Macs: what one seals the other must open, and nothing else must
/// get through, because anything that does is played as sound or moves the clock.
struct WireTests {
    let secret = SymmetricKey(data: Data(repeating: 7, count: 32))
    let salt: [UInt8] = Array(0..<32)

    /// The two ends of one session, keyed the way a paired session keys them.
    func session() -> (initiator: DatagramCrypto, responder: DatagramCrypto) {
        let out = Seal.derive(secret, salt: salt, "duet udp I>R")
        let back = Seal.derive(secret, salt: salt, "duet udp R>I")
        return (DatagramCrypto(send: out, receive: back), DatagramCrypto(send: back, receive: out))
    }

    let payload: [UInt8] = [1, 2, 3, 250, 0, 99]

    @Test func whatOneMacSealsTheOtherOpens() {
        let (initiator, responder) = session()
        let packet = initiator.seal(StreamPacket.audio, payload)
        let opened = responder.open(packet)
        #expect(opened?.type == StreamPacket.audio)
        #expect(opened?.payload == payload)
        // And the other way round, which is the direction the clock answers take.
        let back = responder.seal(StreamPacket.clockAnswer, [7, 7])
        #expect(initiator.open(back)?.payload == [7, 7])
        #expect(initiator.open(back)?.type == StreamPacket.clockAnswer)
    }

    @Test func aMacDoesNotAcceptItsOwnPacketBackFromTheNetwork() {
        let (initiator, responder) = session()
        // The two directions are keyed apart, so a packet reflected back is not sound to play.
        #expect(initiator.open(initiator.seal(StreamPacket.audio, payload)) == nil)
        #expect(responder.open(responder.seal(StreamPacket.audio, payload)) == nil)
    }

    @Test func aPacketFromAnotherPairingIsRejected() {
        let (initiator, _) = session()
        let other = SymmetricKey(data: Data(repeating: 8, count: 32))
        let stranger = DatagramCrypto(send: Seal.derive(other, salt: salt, "duet udp I>R"),
                                      receive: Seal.derive(other, salt: salt, "duet udp R>I"))
        let (_, responder) = session()
        #expect(responder.open(stranger.seal(StreamPacket.audio, payload)) == nil)
        #expect(initiator.open(stranger.seal(StreamPacket.clockAnswer, payload)) == nil)
    }

    @Test func aPacketChangedAnywhereOnTheWayIsRejected() {
        let (initiator, responder) = session()
        let packet = initiator.seal(StreamPacket.audio, payload)
        #expect(responder.open(packet) != nil)
        for i in packet.indices {
            var changed = packet
            changed[i] ^= 0x01          // the type, the counter, the sound, the tag: all of it
            #expect(responder.open(changed) == nil, "byte \(i) was accepted")
        }
    }

    @Test func aPacketCutShortIsRejected() {
        let (initiator, responder) = session()
        let packet = initiator.seal(StreamPacket.audio, payload)
        for length in 0..<packet.count {
            #expect(responder.open(Array(packet.prefix(length))) == nil, "length \(length) was accepted")
        }
    }

    @Test func theSameSoundTwiceIsNeverSealedTheSameWay() {
        let (initiator, responder) = session()
        let first = initiator.seal(StreamPacket.audio, payload)
        let second = initiator.seal(StreamPacket.audio, payload)
        // One key must never seal twice with one counter, and the counter is what is sent in clear.
        #expect(first != second)
        #expect(Array(first[1..<9]) != Array(second[1..<9]))
        #expect(Array(first[9...]) != Array(second[9...]))
        #expect(responder.open(second)?.payload == payload)
    }

    @Test func numbersSurviveTheTripThroughAPacket() {
        var writer = ByteWriter()
        writer.put(UInt32(0xDEAD_BEEF))
        writer.put(Int64(-1_234_567_890_123))
        writer.put(Double.pi)
        writer.put(Float(-0.25))
        writer.put(Int16(-32_768))
        var reader = ByteReader(writer.bytes)
        #expect(reader.get(UInt32.self) == 0xDEAD_BEEF)
        #expect(reader.get(Int64.self) == -1_234_567_890_123)
        #expect(reader.double() == Double.pi)
        #expect(reader.float() == Float(-0.25))
        #expect(reader.get(Int16.self) == -32_768)
        #expect(reader.get(UInt8.self) == nil)      // nothing left, and it says so
    }

    @Test func aNumberThatDoesNotFitInWhatIsLeftIsRefused() {
        var writer = ByteWriter()
        writer.put(UInt32(5))
        var reader = ByteReader(writer.bytes)
        #expect(reader.get(UInt64.self) == nil)     // not 8 bytes there, so no number
        #expect(reader.get(UInt32.self) == 5)       // and nothing was consumed by the refusal
    }

    @Test func numbersAreReadFromWhereThePacketSliceStarts() {
        var writer = ByteWriter()
        writer.put(UInt8(0xAA))                     // a header byte, as a packet has
        writer.put(UInt64(0x0102_0304_0506_0708))
        var reader = ByteReader(writer.bytes[1..<9])
        #expect(reader.u64() == 0x0102_0304_0506_0708)
    }
}
