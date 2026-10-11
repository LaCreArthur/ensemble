import Foundation
import Network

public struct NetError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Blocking TCP stream over Network.framework, for code that runs on its own thread.
/// With a session set, every byte in both directions goes through HAP encryption.
final class TCPStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "duet.tcp")
    var session: HAPSession?
    private var buffer = [UInt8]()

    init(endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        connection = NWConnection(to: endpoint, using: parameters)
    }

    convenience init(host: String, port: UInt16) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
    }

    func open(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error), .waiting(let error): failure = error; ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        if ready.wait(timeout: .now() + timeout) == .timedOut { close(); throw NetError("connect timed out") }
        connection.stateUpdateHandler = nil
        if let failure { close(); throw failure }
    }

    func close() { connection.cancel() }

    var remoteIP: String? { Self.ip(connection.currentPath?.remoteEndpoint) }
    var localIP: String? { Self.ip(connection.currentPath?.localEndpoint) }

    private static func ip(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first
        case .ipv6(let a): return "\(a)"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    func write(_ bytes: [UInt8]) throws {
        let data = Data(session?.encrypt(bytes) ?? bytes)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        connection.send(content: data, completion: .contentProcessed { error in failure = error; done.signal() })
        if done.wait(timeout: .now() + 5) == .timedOut { throw NetError("send timed out") }
        if let failure { throw failure }
    }

    /// Reads plaintext bytes until `predicate` finds a complete message in the buffer.
    /// The predicate returns how many bytes the message takes, or nil to keep reading.
    func read(timeout: TimeInterval, until predicate: ([UInt8]) -> Int?) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let n = predicate(buffer) {
                let message = Array(buffer[0..<n])
                buffer.removeFirst(n)
                return message
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw NetError("read timed out") }
            let chunk = try receiveChunk(timeout: remaining)
            buffer += try session?.decrypt(chunk) ?? chunk
        }
    }

    private func receiveChunk(timeout: TimeInterval) throws -> [UInt8] {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [UInt8] = []
        nonisolated(unsafe) var failure: Error?
        nonisolated(unsafe) var closed = false
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data { result = [UInt8](data) }
            failure = error
            closed = isComplete && (data?.isEmpty ?? true)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { throw NetError("read timed out") }
        if let failure { throw failure }
        if closed { throw NetError("connection closed by peer") }
        return result
    }
}

/// Plain BSD UDP socket (IPv4), bound to an ephemeral port.
final class UDPSocket: @unchecked Sendable {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw NetError("socket failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { Darwin.close(fd); throw NetError("bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
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

    /// Waits up to 200 ms for one datagram.
    func receive() -> ([UInt8], sockaddr_in)? {
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBytes { b in
            withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, b.baseAddress, b.count, 0, $0, &length)
            } }
        }
        guard n > 0 else { return nil }
        return (Array(buffer[0..<n]), from)
    }
}
