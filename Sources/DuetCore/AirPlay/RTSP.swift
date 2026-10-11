import Foundation

/// One RTSP or HTTP message (request or response) as AirPlay uses them.
struct RTSPMessage: CustomStringConvertible {
    var firstLine: String
    var headers: [(String, String)] = []
    var body: [UInt8] = []

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    /// Status code of a response ("RTSP/1.0 200 OK" -> 200).
    var status: Int { Int(firstLine.split(separator: " ").dropFirst().first ?? "") ?? 0 }

    var plist: [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: Data(body), format: nil)) as? [String: Any]
    }

    func serialized() -> [UInt8] {
        var text = firstLine + "\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        if !body.isEmpty || firstLine.hasPrefix("RTSP/") || firstLine.hasPrefix("HTTP/") { text += "Content-Length: \(body.count)\r\n" }
        text += "\r\n"
        return Array(text.utf8) + body
    }

    /// Length of the first complete message in `buffer`, or nil if it is not complete yet.
    static func completeLength(_ buffer: [UInt8]) -> Int? {
        guard let end = headerEnd(buffer) else { return nil }
        let head = String(decoding: buffer[0..<end], as: UTF8.self)
        let length = head.split(separator: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        return buffer.count >= end + 4 + length ? end + 4 + length : nil
    }

    static func parse(_ bytes: [UInt8]) -> RTSPMessage {
        let end = headerEnd(bytes) ?? bytes.count
        let lines = String(decoding: bytes[0..<end], as: UTF8.self).components(separatedBy: "\r\n")
        var message = RTSPMessage(firstLine: lines.first ?? "")
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { message.headers.append((String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces))) }
        }
        if end + 4 <= bytes.count { message.body = Array(bytes[(end + 4)...]) }
        return message
    }

    private static func headerEnd(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        for i in 0...(b.count - 4) where b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10 { return i }
        return nil
    }

    var description: String {
        var text = firstLine + headers.map { "\n  \($0.0): \($0.1)" }.joined()
        if let plist { text += "\n  \(plist)" } else if !body.isEmpty { text += "\n  <\(body.count) bytes>" }
        return text
    }
}

/// Sequential RTSP client on one TCP connection (the AirPlay control connection).
final class RTSPClient {
    let stream: TCPStream
    let sessionID = UInt32.random(in: 1...UInt32.max)
    let dacpID = String(format: "%016llX", UInt64.random(in: 1...UInt64.max))
    let activeRemote = UInt32.random(in: 1...UInt32.max)
    private var cseq = 0
    var log: ((String) -> Void)?

    init(stream: TCPStream) { self.stream = stream }

    var uri: String { "rtsp://\(stream.localIP ?? "127.0.0.1")/\(sessionID)" }

    @discardableResult
    func request(_ method: String, _ path: String? = nil, protocol proto: String = "RTSP/1.0",
                 headers extra: [(String, String)] = [], plist: [String: Any]? = nil,
                 body: [UInt8] = [], contentType: String? = nil) throws -> RTSPMessage {
        var message = RTSPMessage(firstLine: "\(method) \(path ?? uri) \(proto)")
        var body = body
        var contentType = contentType
        if let plist {
            body = [UInt8](try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0))
            contentType = "application/x-apple-binary-plist"
        }
        if proto.hasPrefix("RTSP") {
            message.headers = [("CSeq", "\(cseq)"), ("DACP-ID", dacpID), ("Active-Remote", "\(activeRemote)"),
                               ("Client-Instance", dacpID), ("User-Agent", "AirPlay/550.10")]
            cseq += 1
        }
        message.headers += extra
        if let contentType { message.headers.append(("Content-Type", contentType)) }
        message.body = body
        log?("> \(message)")
        try stream.write(message.serialized())
        let response = RTSPMessage.parse(try stream.read(timeout: 5, until: RTSPMessage.completeLength))
        log?("< \(response)")
        return response
    }
}
