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

/// Plain BSD UDP socket (IPv4), on an ephemeral port unless one is given.
final class UDPSocket: @unchecked Sendable {
    let fd: Int32
    let port: UInt16

    init(port: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw LinkError("socket failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = port.bigEndian
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { Darwin.close(fd); throw LinkError("bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        var service = Int32(NET_SERVICE_TYPE_VO)   // voice class: Wi-Fi gives it the low-latency queue
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, socklen_t(MemoryLayout<Int32>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &on, socklen_t(MemoryLayout<Int32>.size))
        self.fd = fd
        self.port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { Darwin.close(fd) }

    static func address(_ ip: String, _ port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)
        return addr
    }

    func send(_ bytes: [UInt8], to address: sockaddr_in) {
        var a = address
        _ = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
    }

    /// Waits up to `timeout` seconds for one datagram. Returns it with its sender and the host time
    /// (seconds) at which the kernel received it, free of this thread's wake-up delay.
    func receive(timeout: Double) -> (bytes: [UInt8], from: sockaddr_in, arrival: Double)? {
        var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&request, 1, Int32(max(0, timeout * 1000).rounded(.up))) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var control = [UInt8](repeating: 0, count: 64)
        let n = buffer.withUnsafeMutableBytes { data in
            control.withUnsafeMutableBytes { control in
                withUnsafeMutablePointer(to: &from) { from in
                    var vector = iovec(iov_base: data.baseAddress, iov_len: data.count)
                    return withUnsafeMutablePointer(to: &vector) { vector in
                        var message = msghdr(msg_name: UnsafeMutableRawPointer(from), msg_namelen: socklen_t(MemoryLayout<sockaddr_in>.size),
                                             msg_iov: vector, msg_iovlen: 1,
                                             msg_control: control.baseAddress, msg_controllen: socklen_t(control.count), msg_flags: 0)
                        return recvmsg(fd, &message, 0)
                    }
                }
            }
        }
        guard n > 0 else { return nil }
        // Control message: cmsghdr (len, level, type: 12 bytes), then the mach_absolute_time stamp.
        var arrival = HostClock.now
        let length = control.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let level = control.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }
        let type = control.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int32.self) }
        if length >= 20, level == SOL_SOCKET, type == SCM_TIMESTAMP_MONOTONIC {
            arrival = HostClock.seconds(control.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) })
        }
        return (Array(buffer[0..<n]), from, arrival)
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
