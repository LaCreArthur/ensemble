import CryptoKit
import Foundation
import Network
import Synchronization

/// Streams the captured sound to an AirPlay 2 receiver (the other Mac's built-in AirPlay Receiver)
/// as a realtime PCM stream, timed so that it plays each frame exactly when this Mac's speaker does.
///
/// Timeline: capture frame X (device rate) is heard on this Mac at H(X), given by the capture engine's
/// anchor. Stream frame j (44.1 kHz) carries the sound at capture position X0 + j * rate / 44100 and
/// has RTP timestamp R0 + j. Sync packets tell the receiver "RTP frame W plays at clock time T" with
/// T = H(position of W), on a clock we serve over NTP from this Mac's host clock.
public final class AirPlaySender: @unchecked Sendable {
    public enum State: Equatable, Sendable { case connecting, streaming, stopped, failed(String) }

    public let endpoint: NWEndpoint
    public var onState: (@Sendable (State) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    private let capture: CaptureEngine
    private let running = Atomic<Bool>(false)
    private let volumeBits = Atomic<UInt32>(Float(0).bitPattern)
    private let volumeDirty = Atomic<Bool>(true)
    private var thread: Thread?

    static let streamRate = 44100
    static let framesPerPacket = 352

    public init(endpoint: NWEndpoint, capture: CaptureEngine) {
        self.endpoint = endpoint
        self.capture = capture
    }

    /// Receiver volume in dB, -30...0 (AirPlay scale); below -30 means mute.
    public var volumeDB: Float {
        get { Float(bitPattern: volumeBits.load(ordering: .relaxed)) }
        set { volumeBits.store(newValue.bitPattern, ordering: .relaxed); volumeDirty.store(true, ordering: .relaxed) }
    }

    public func start() {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let t = Thread { [weak self] in self?.session() }
        t.name = "duet.airplay"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() { running.store(false, ordering: .releasing) }

    private func log(_ text: String) { onLog?(text) }

    // MARK: Session (control connection), runs on its own thread

    private func session() {
        onState?(.connecting)
        var cleanup: [() -> Void] = []
        defer { cleanup.reversed().forEach { $0() } }
        do {
            let control = TCPStream(endpoint: endpoint)
            try control.open()
            cleanup.append { control.close() }
            guard let remoteIP = control.remoteIP else { throw NetError("no receiver address") }
            log("connected to \(remoteIP)")
            let rtsp = RTSPClient(stream: control)
            rtsp.log = onLog

            let sharedSecret = try pairTransient(rtsp)
            control.session = HAPSession(outKey: HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Write-Encryption-Key"),
                                         inKey: HAPCrypto.hkdf(sharedSecret, salt: "Control-Salt", info: "Control-Read-Encryption-Key"))

            let clock = NTPClock()
            let timingSocket = try UDPSocket(), controlSocket = try UDPSocket(), audioSocket = try UDPSocket()
            startLoop("duet.timing") { [self] in
                while self.running.load(ordering: .relaxed) { Self.answerTiming(timingSocket, clock: clock) }
            }

            let setup = try rtsp.request("SETUP", plist: [
                "deviceID": "AA:BB:CC:DD:EE:FF", "sessionUUID": UUID().uuidString, "timingPort": Int(timingSocket.port),
                "timingProtocol": "NTP", "isMultiSelectAirPlay": true, "groupContainsGroupLeader": false,
                "macAddress": "AA:BB:CC:DD:EE:FF", "model": "iPhone14,3", "name": "Duet", "osBuildVersion": "20F66",
                "osName": "iPhone OS", "osVersion": "16.5", "senderSupportsRelay": false, "sourceVersion": "690.7.1",
                "statsCollectionEnabled": false,
            ])
            guard setup.status == 200, let eventPort = setup.plist?["eventPort"] as? Int else { throw NetError("SETUP failed: \(setup.firstLine)") }

            let events = TCPStream(host: remoteIP, port: UInt16(eventPort))
            try events.open()
            cleanup.append { events.close() }
            events.session = HAPSession(outKey: HAPCrypto.hkdf(sharedSecret, salt: "Events-Salt", info: "Events-Read-Encryption-Key"),
                                        inKey: HAPCrypto.hkdf(sharedSecret, salt: "Events-Salt", info: "Events-Write-Encryption-Key"))
            startLoop("duet.events") { [self] in
                while self.running.load(ordering: .relaxed) {
                    guard let raw = try? events.read(timeout: 0.5, until: RTSPMessage.completeLength) else { continue }
                    let request = RTSPMessage.parse(raw)
                    self.log("event < \(request)")
                    var reply = RTSPMessage(firstLine: "RTSP/1.0 200 OK", headers: [("Audio-Latency", "0")])
                    if let server = request.header("Server") { reply.headers.append(("Server", server)) }
                    if let cseq = request.header("CSeq") { reply.headers.append(("CSeq", cseq)) }
                    try? events.write(reply.serialized())
                }
            }

            let streamKey = (0..<32).map { _ in UInt8.random(in: 0...255) }
            let streamSetup = try rtsp.request("SETUP", plist: ["streams": [[
                "audioFormat": 0x800, "audioMode": "default", "controlPort": Int(controlSocket.port), "ct": 1,
                "isMedia": true, "latencyMax": 88200, "latencyMin": 11025, "shk": Data(streamKey),
                "spf": Self.framesPerPacket, "sr": Self.streamRate, "type": 0x60,
                "supportsDynamicStreamID": false, "streamConnectionID": Int(rtsp.sessionID),
            ] as [String: Any]]])
            guard streamSetup.status == 200,
                  let stream = (streamSetup.plist?["streams"] as? [[String: Any]])?.first,
                  let dataPort = stream["dataPort"] as? Int, let receiverControlPort = stream["controlPort"] as? Int
            else { throw NetError("stream SETUP failed: \(streamSetup.firstLine)") }

            let audio = AudioStream(capture: capture, clock: clock, key: streamKey, ssrc: rtsp.sessionID,
                                    audioSocket: audioSocket, controlSocket: controlSocket,
                                    data: UDPSocket.address(remoteIP, UInt16(dataPort)),
                                    control: UDPSocket.address(remoteIP, UInt16(receiverControlPort)))
            startLoop("duet.retransmit") { [self] in
                while self.running.load(ordering: .relaxed) { audio.serveRetransmits() }
            }
            try check(rtsp.request("RECORD"), "RECORD")
            try check(rtsp.request("FLUSH", headers: [("Range", "npt=0-"), ("Session", "0"),
                                                      ("RTP-Info", "seq=\(audio.firstSequence);rtptime=\(audio.firstTimestamp)")]), "FLUSH")
            startLoop("duet.audio", priority: 0.9) { [self] in
                while self.running.load(ordering: .relaxed) { audio.pump(); usleep(2000) }
            }
            onState?(.streaming)
            var lastFeedback = Date.distantPast
            while running.load(ordering: .relaxed) {
                if volumeDirty.exchange(false, ordering: .relaxed) {
                    let db = volumeDB < -30 ? -144 : max(-30, min(0, volumeDB))
                    try check(rtsp.request("SET_PARAMETER", body: Array("volume: \(String(format: "%.6f", db))\r\n".utf8),
                                           contentType: "text/parameters"), "volume")
                }
                if Date().timeIntervalSince(lastFeedback) >= 2 {
                    try check(rtsp.request("POST", "/feedback"), "feedback")
                    lastFeedback = Date()
                }
                usleep(50_000)
            }
            _ = try? rtsp.request("TEARDOWN")
            onState?(.stopped)
        } catch {
            running.store(false, ordering: .releasing)
            log("failed: \(error)")
            onState?(.failed("\(error)"))
        }
    }

    private func check(_ response: RTSPMessage, _ what: String) throws {
        if response.status != 200 { throw NetError("\(what): \(response.firstLine)") }
    }

    private func startLoop(_ name: String, priority: Double = 0.7, _ body: @escaping @Sendable () -> Void) {
        let t = Thread(block: body)
        t.name = name
        t.threadPriority = priority
        t.start()
    }

    /// HAP transient pairing (SRP with the fixed PIN 3939, no long-term keys). Returns the shared secret.
    private func pairTransient(_ rtsp: RTSPClient) throws -> [UInt8] {
        let headers = [("User-Agent", "AirPlay/320.20"), ("Connection", "keep-alive"), ("X-Apple-HKP", "4")]
        let type = "application/octet-stream"
        _ = try rtsp.request("POST", "/pair-pin-start", protocol: "HTTP/1.1", headers: headers, contentType: type)
        let m2 = try rtsp.request("POST", "/pair-setup", protocol: "HTTP/1.1", headers: headers,
                                  body: [UInt8](TLV8.encode([(TLV8.method, [0]), (TLV8.seqNo, [1]), (TLV8.flags, [0x10])])), contentType: type)
        let tlv2 = TLV8.decode(Data(m2.body))
        guard m2.status == 200, let salt = tlv2[TLV8.salt], let serverPublic = tlv2[TLV8.publicKey] else {
            throw NetError("pairing refused (\(m2.firstLine), error \(tlv2[TLV8.error] ?? []))")
        }
        guard let srp = SRPClient().respond(salt: salt, serverPublic: .init(Data(serverPublic)), password: "3939") else {
            throw NetError("bad pairing key")
        }
        let m4 = try rtsp.request("POST", "/pair-setup", protocol: "HTTP/1.1", headers: headers,
                                  body: [UInt8](TLV8.encode([(TLV8.seqNo, [3]), (TLV8.publicKey, srp.publicKey), (TLV8.proof, srp.proof)])), contentType: type)
        let tlv4 = TLV8.decode(Data(m4.body))
        guard m4.status == 200, tlv4[TLV8.proof] == srp.expectedServerProof else {
            throw NetError("pairing proof rejected (\(m4.firstLine), error \(tlv4[TLV8.error] ?? []))")
        }
        return srp.sessionKey
    }

    /// Answers one NTP-style timing request from the receiver, if one arrives within 200 ms.
    private static func answerTiming(_ socket: UDPSocket, clock: NTPClock) {
        guard let (request, from) = socket.receive(), request.count >= 32 else { return }
        let now = clock.now()
        var reply = [request[0], 0xD3, 0x00, 0x07, 0, 0, 0, 0]
        reply += request[24..<32]   // origin: the time the receiver sent its request
        reply += now + now          // receive and transmit time
        socket.send(reply, to: from)
    }
}

/// Our side of the AirPlay timing protocol: NTP 32.32 timestamps derived from the host clock,
/// so they share one time base with CoreAudio's timestamps.
final class NTPClock: @unchecked Sendable {
    let ticksPerSecond: Double
    private let offset: Double

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        ticksPerSecond = 1e9 * Double(tb.denom) / Double(tb.numer)
        offset = Date().timeIntervalSince1970 + 2_208_988_800 - Double(mach_absolute_time()) / ticksPerSecond
    }

    func hostSeconds(_ ticks: UInt64) -> Double { Double(ticks) / ticksPerSecond }

    /// NTP timestamp (8 bytes, big-endian) for a host time in seconds.
    func ntp(_ hostSeconds: Double) -> [UInt8] {
        let t = hostSeconds + offset
        let seconds = UInt32(truncatingIfNeeded: Int64(t.rounded(.down)))
        let fraction = UInt32(min(4_294_967_295, (t - t.rounded(.down)) * 4_294_967_296))
        return seconds.bigEndianBytes + fraction.bigEndianBytes
    }

    func now() -> [UInt8] { ntp(hostSeconds(mach_absolute_time())) }
}

extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: self.bigEndian) { Array($0) } }
}
