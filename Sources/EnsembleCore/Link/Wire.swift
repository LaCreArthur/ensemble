import CryptoKit
import Foundation
import Synchronization

public struct LinkError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// ChaCha20-Poly1305 with 96-bit nonces made of 4 zero bytes and a 64-bit little-endian counter.
enum Seal {
    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: [0, 0, 0, 0] + counter.littleEndianBytes)
    }

    static func seal(_ plain: [UInt8], key: SymmetricKey, counter: UInt64, aad: [UInt8]) -> [UInt8] {
        let box = try! ChaChaPoly.seal(plain, using: key, nonce: nonce(counter), authenticating: aad)
        return Array(box.ciphertext) + Array(box.tag)
    }

    static func open(_ sealed: ArraySlice<UInt8>, key: SymmetricKey, counter: UInt64, aad: ArraySlice<UInt8>) -> [UInt8]? {
        guard sealed.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        else { return nil }
        return (try? ChaChaPoly.open(box, using: key, authenticating: aad)).map { Array($0) }
    }

    static func derive(_ secret: SymmetricKey, salt: [UInt8], _ info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: salt, info: Data(info.utf8), outputByteCount: 32)
    }
}

/// Encrypts and authenticates the datagrams of one session: [type][counter][sealed payload], with
/// type and counter authenticated in clear. One instance per session and direction pair, so a
/// counter (the nonce) is never used twice with one key. Safe to use from several threads.
public final class DatagramCrypto: @unchecked Sendable {
    private let sendKey: SymmetricKey, receiveKey: SymmetricKey
    private let counter = Atomic<UInt64>(0)

    init(send: SymmetricKey, receive: SymmetricKey) { sendKey = send; receiveKey = receive }

    func seal(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let n = counter.wrappingAdd(1, ordering: .relaxed).oldValue
        let clear = [type] + n.littleEndianBytes
        return clear + Seal.seal(payload, key: sendKey, counter: n, aad: clear)
    }

    /// Returns the type and the payload if the packet is authentic.
    func open(_ packet: [UInt8]) -> (type: UInt8, payload: [UInt8])? {
        guard packet.count >= 9 + 16 else { return nil }
        var reader = ByteReader(packet[1..<9])
        guard let n = reader.u64(), let payload = Seal.open(packet[9...], key: receiveKey, counter: n, aad: packet[..<9]) else { return nil }
        return (packet[0], payload)
    }
}

/// Host clock in seconds (mach_absolute_time, the clock CoreAudio timestamps use).
enum HostClock {
    static let ticksPerSecond: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return 1e9 * Double(tb.denom) / Double(tb.numer)
    }()
    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }
    static var now: Double { seconds(mach_absolute_time()) }
}

struct ByteWriter {
    var bytes: [UInt8] = []
    mutating func put<T: FixedWidthInteger>(_ v: T) { bytes += v.littleEndianBytes }
    mutating func put(_ v: Double) { put(v.bitPattern) }
    mutating func put(_ v: Float) { put(v.bitPattern) }
}

struct ByteReader {
    private let bytes: ArraySlice<UInt8>
    private var offset: Int
    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes; offset = bytes.startIndex }
    init(_ bytes: [UInt8]) { self.init(bytes[...]) }

    mutating func get<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= bytes.endIndex else { return nil }
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes[offset..<offset + size]) }
        offset += size
        return T(littleEndian: value)
    }
    mutating func u64() -> UInt64? { get(UInt64.self) }
    mutating func double() -> Double? { get(UInt64.self).map(Double.init(bitPattern:)) }
    mutating func float() -> Float? { get(UInt32.self).map(Float.init(bitPattern:)) }
}

extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: self.littleEndian) { Array($0) } }
}
