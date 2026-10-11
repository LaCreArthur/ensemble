import CryptoKit
import Foundation
import Network
import dnssd
import os

/// The control link to the other Mac running Duet. It finds the other Mac on the local network
/// (Bonjour), pairs with it once, and then keeps an encrypted session with it: small JSON messages
/// over TCP, plus the keys of the sound stream (UDP). One paired Mac at a time. Main queue only.
///
/// Where the network keeps the Macs apart (or there is none), they find each other over the direct
/// Mac-to-Mac link, as AirDrop does. That link slows the Mac's Wi-Fi while it is on, so each Mac uses
/// it only while it looks for the other one: from `directAfter` without a session until `directFor`
/// after it started, woke or lost its session, and for the life of a session that needed it.
///
/// Pairing (numeric comparison, as in Bluetooth): the Mac where the user clicks Pair (I) and the
/// other (R) exchange X25519 keys; R commits to its nonce before I reveals its own, so a machine in
/// the middle has one chance in a million to make both codes match. Both Macs show the code; each
/// keeps the secret only once its user confirmed and the other Mac proved it holds the same secret.
///
/// Session: the Mac with the smaller ID connects. Each side sends a fresh nonce in clear, and every
/// key of the session comes from the pairing secret and both nonces, so nothing recorded from an
/// earlier session can be replayed. Frames: a 2-byte length, then ChaCha20-Poly1305 with one counter
/// per direction as nonce (the length is authenticated). A side that has no pairing with the
/// caller answers "unpaired" in clear; nothing unauthenticated ever changes or deletes a pairing.
@MainActor
public final class Link {
    public struct Peer: Hashable, Sendable {
        public let id: String
        public let name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// The Mac this one trusts, and the secret both keep from the pairing.
    public struct Pairing: Sendable {
        public let peer: Peer
        public let key: SymmetricKey
        public init(peer: Peer, key: SymmetricKey) { self.peer = peer; self.key = key }
    }

    /// The authenticated session with the paired Mac.
    public struct Session {
        public let peer: Peer
        /// Keys for the sound stream of this session.
        public let crypto: DatagramCrypto
    }

    public let me: Peer
    public private(set) var pairing: Pairing?
    /// Duets on the network now, apart from this one.
    public private(set) var nearby: [Peer] = []
    public private(set) var session: Session?
    /// What the pairing or the connection does now, for the menu (nil: nothing to say).
    public private(set) var note: String?
    /// The paired Mac answered that it does not know this one: it needs a new pairing.
    public private(set) var refused = false
    /// The user did not allow this app on the local network (Privacy & Security), so it finds no Mac.
    public private(set) var denied = false
    /// Duets on the network to offer pairing with: all but the paired one, unless it refused.
    public var pairable: [Peer] {
        channels.contains { $0.exchange != nil } ? [] : nearby.filter { $0.id != pairing?.peer.id || refused }
    }

    public var onChange: () -> Void = {}
    /// A message from the paired Mac (authenticated).
    public var onMessage: ([String: Any]) -> Void = { _ in }
    /// Keeps a new pairing; called once both Macs confirmed it.
    public var onPaired: (Pairing) -> Void = { _ in }
    /// Asks the user to compare `code` with the one the other Mac shows; `reply` once answered.
    public var confirm: (_ peer: Peer, _ code: String, _ reply: @escaping (Bool) -> Void) -> Void = { _, _, reply in reply(false) }

    private static let type = "_duet._tcp"
    /// How long the Macs try the network alone before they also use the direct link, and how long they then look.
    private static let directAfter: TimeInterval = 10, directFor: TimeInterval = 600
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var channels: [Channel] = []
    private weak var sessionChannel: Channel?
    private var timer: Timer?
    /// The listener and the browser use the direct link too.
    private var direct = false
    /// Since when this Mac looks for the other one (start, wake, end of a session).
    private var lookingSince = Date()
    private let log = Logger(subsystem: "com.lacrearthur.duet", category: "link")

    public init(me: Peer, pairing: Pairing?) {
        self.me = me
        self.pairing = pairing
    }

    public func start() {
        discover()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
    }

    /// Looks for the other Mac again if this Mac stopped looking: on wake, or when the user opens the menu.
    public func lookAgain() {
        guard session == nil, -lookingSince.timeIntervalSinceNow >= Self.directFor else { return }
        lookingSince = Date()
        updateDirect()
    }

    /// Starts pairing with a Duet found on the network; both Macs then ask their user to confirm.
    public func pair(with peer: Peer) {
        guard let endpoint = endpoints[peer.id], !channels.contains(where: { $0.exchange != nil }) else { return }
        let channel = Channel(NWConnection(to: endpoint, using: Self.parameters(direct: direct)), initiator: true)
        channel.peer = peer
        channel.exchange = Exchange()
        note = "Pairing with \(peer.name)…"
        add(channel)
        onChange()
    }

    /// Sends a message to the paired Mac if the session is up (dropped otherwise).
    public func send(_ message: [String: Any]) { sessionChannel?.send(message) }

    // MARK: Network

    /// TCP; keepalive notices a vanished Mac within about 5 s.
    private static func parameters(direct: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = direct
        return parameters
    }

    /// (Re)starts the listener and the browser, on the direct link too if `direct`.
    private func discover() {
        listener?.cancel()
        browser?.cancel()
        listen()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.type, domain: nil), using: Self.parameters(direct: direct))
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated { if let self, browser === self.browser { self.found(results) } }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, browser === self.browser else { return }
                let denied: Bool
                switch state {
                case .ready: denied = false
                case .waiting(.dns(let code)), .failed(.dns(let code)): denied = code == kDNSServiceErr_PolicyDenied
                default: return
                }
                guard denied != self.denied else { return }
                self.denied = denied
                self.onChange()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func listen() {
        guard let listener = try? NWListener(using: Self.parameters(direct: direct)) else { return }
        listener.service = NWListener.Service(name: me.name, type: Self.type, txtRecord: NWTXTRecord(["id": me.id]))
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.add(Channel(connection, initiator: false)) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                guard let listener, listener === self?.listener else { return }
                listener.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { if let self, listener === self.listener { self.listen() } }
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// Turns the direct link on or off for the listener and the browser (see the type's notes).
    private func updateDirect() {
        let looking = -lookingSince.timeIntervalSinceNow
        let wanted = session == nil ? looking >= Self.directAfter && looking < Self.directFor : sessionChannel?.direct == true
        guard wanted != direct else { return }
        direct = wanted
        log.notice("direct link \(wanted ? "on" : "off", privacy: .public)")
        discover()
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var endpoints = [String: NWEndpoint]()
        var nearby = [Peer]()
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let id = txt["id"], id != me.id, endpoints[id] == nil,
                  case .service(let name, _, _, _) = result.endpoint else { continue }
            endpoints[id] = result.endpoint
            nearby.append(Peer(id: id, name: name))
        }
        self.endpoints = endpoints
        self.nearby = nearby.sorted { $0.name < $1.name }
        reconcile()
        onChange()
    }

    /// Connects to the paired Mac when this Mac is the one that connects and nothing is under way.
    private func reconcile() {
        updateDirect()
        guard let peer = pairing?.peer, !refused, session == nil, me.id < peer.id,
              !channels.contains(where: { $0.initiator || $0.authenticated }), let endpoint = endpoints[peer.id] else { return }
        let channel = Channel(NWConnection(to: endpoint, using: Self.parameters(direct: direct)), initiator: true)
        channel.direct = direct
        add(channel)
    }

    private func add(_ channel: Channel) {
        channels.append(channel)
        channel.onReady = { [weak self] channel in self?.ready(channel) }
        channel.onFrame = { [weak self] channel, message in self?.received(channel, message) }
        channel.onClose = { [weak self] channel in self?.closed(channel) }
        channel.start()
        // A connection that neither authenticates nor pairs within 10 s is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak channel] in
            MainActor.assumeIsolated { if let channel, !channel.authenticated, channel.exchange == nil { channel.close() } }
        }
    }

    private func closed(_ channel: Channel) {
        channels.removeAll { $0 === channel }
        if channel.exchange != nil, note?.hasPrefix("Pairing") == true { note = nil }
        if channel === sessionChannel || session != nil && sessionChannel == nil {
            log.notice("session ended")
            session = nil
            // After a session over the direct link, look over it again at once: the network did not do.
            lookingSince = Date() - (channel.direct ? Self.directAfter : 0)
            updateDirect()
            onChange()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in MainActor.assumeIsolated { self?.reconcile() } }
    }

    // MARK: Protocol

    private func ready(_ channel: Channel) {
        guard channel.initiator else { return }
        if let exchange = channel.exchange {
            channel.send(["t": "pair", "id": me.id, "name": me.name, "pk": base64(exchange.publicKey)])
        } else {
            channel.nonce = randomBytes(16)
            channel.send(["t": "hello", "id": me.id, "name": me.name, "n": base64(channel.nonce), "d": channel.direct])
        }
    }

    private func received(_ channel: Channel, _ message: [String: Any]) {
        let type = message["t"] as? String ?? ""
        if channel.authenticated { return onMessage(message) }
        switch type {
        case "hello": hello(channel, message)
        case "ready":
            // The first frame sealed with the session keys: the other Mac holds the pairing secret.
            guard channel.isSealed, let peer = channel.peer, let crypto = channel.udp else { return channel.close() }
            channel.authenticated = true
            for other in channels where other !== channel && other.authenticated { other.close() }
            sessionChannel = channel
            session = Session(peer: peer, crypto: crypto)
            refused = false
            if note != nil, channel.exchange == nil { note = nil }
            let path = channel.connection.currentPath?.availableInterfaces.map(\.name).joined(separator: ",") ?? "?"
            log.notice("session with \(peer.name, privacy: .public) over \(channel.direct ? "the direct link" : "the network", privacy: .public) (\(path, privacy: .public))")
            updateDirect()
            onChange()
        case "unpaired":
            guard channel.initiator, channel.exchange == nil else { return channel.close() }
            refused = true
            note = "\(pairing?.peer.name ?? "The other Mac") does not know this Mac any more: pair again."
            channel.close()
            onChange()
        default: pairStep(channel, type, message)
        }
    }

    private func hello(_ channel: Channel, _ message: [String: Any]) {
        guard !channel.isSealed, channel.exchange == nil, let id = message["id"] as? String, let name = message["name"] as? String,
              let theirs = bytes(message["n"]), theirs.count == 16 else { return channel.close() }
        guard let pairing, pairing.peer.id == id else {
            if !channel.initiator { channel.send(["t": "unpaired"]) { channel.close() } } else { channel.close() }
            return
        }
        channel.peer = Peer(id: id, name: name)
        let salt: [UInt8]
        if channel.initiator {
            salt = channel.nonce + theirs
        } else {
            channel.direct = direct
            channel.nonce = randomBytes(16)
            channel.send(["t": "hello", "id": me.id, "name": me.name, "n": base64(channel.nonce), "d": direct])
            salt = theirs + channel.nonce
        }
        // A session counts as direct only if both Macs were looking over the direct link when it started.
        channel.direct = channel.direct && message["d"] as? Bool == true
        let (out, back) = channel.initiator ? ("I>R", "R>I") : ("R>I", "I>R")
        channel.seal(send: Seal.derive(pairing.key, salt: salt, "duet tcp " + out),
                     receive: Seal.derive(pairing.key, salt: salt, "duet tcp " + back))
        channel.udp = DatagramCrypto(send: Seal.derive(pairing.key, salt: salt, "duet udp " + out),
                                     receive: Seal.derive(pairing.key, salt: salt, "duet udp " + back))
        channel.send(["t": "ready"])
    }

    /// One pairing in progress on a channel.
    fileprivate final class Exchange {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let nonce = randomBytes(16)
        var theirKey: [UInt8] = []
        var theirNonce: [UInt8] = []
        var commitment: [UInt8] = []
        var secret: SymmetricKey?
        var confirmedHere = false, confirmedThere = false
        var publicKey: [UInt8] { [UInt8](key.publicKey.rawRepresentation) }
    }

    private func pairStep(_ channel: Channel, _ type: String, _ message: [String: Any]) {
        guard !channel.isSealed else { return channel.close() }
        switch (type, channel.initiator) {
        case ("pair", false):
            guard channel.exchange == nil, !channels.contains(where: { $0.exchange != nil }),
                  let id = message["id"] as? String, let name = message["name"] as? String,
                  let key = bytes(message["pk"]), key.count == 32 else { return channel.close() }
            let x = Exchange()
            x.theirKey = key
            x.commitment = sha256(x.publicKey + key + x.nonce)
            channel.exchange = x
            channel.peer = Peer(id: id, name: name)
            note = "Pairing with \(name)…"
            channel.send(["t": "pair1", "pk": base64(x.publicKey), "c": base64(x.commitment)])
            onChange()
        case ("pair1", true):
            guard let x = channel.exchange, x.theirKey.isEmpty, let key = bytes(message["pk"]), key.count == 32,
                  let commitment = bytes(message["c"]), commitment.count == 32 else { return channel.close() }
            x.theirKey = key
            x.commitment = commitment
            channel.send(["t": "pair2", "n": base64(x.nonce)])
        case ("pair2", false):
            guard let x = channel.exchange, x.theirNonce.isEmpty, let n = bytes(message["n"]), n.count == 16 else { return channel.close() }
            x.theirNonce = n
            channel.send(["t": "pair3", "n": base64(x.nonce)])
            agree(channel)
        case ("pair3", true):
            guard let x = channel.exchange, !x.commitment.isEmpty, x.theirNonce.isEmpty, let n = bytes(message["n"]), n.count == 16,
                  sha256(x.theirKey + x.publicKey + n) == x.commitment else { return channel.close() }
            x.theirNonce = n
            agree(channel)
        case ("pairOK", _):
            guard let x = channel.exchange, let secret = x.secret, let proof = bytes(message["mac"]),
                  proof == confirmation(secret, role: channel.initiator ? "R" : "I") else { return channel.close() }
            x.confirmedThere = true
            finishPairing(channel)
        case ("pairNo", _):
            note = "Pairing cancelled on \(channel.peer?.name ?? "the other Mac")."
            channel.close()
            onChange()
        default:
            channel.close()
        }
    }

    /// Both nonces are known: derive the secret and the code, and ask the user.
    private func agree(_ channel: Channel) {
        guard let x = channel.exchange, let peer = channel.peer,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: x.theirKey),
              let shared = try? x.key.sharedSecretFromKeyAgreement(with: theirs) else { return channel.close() }
        let (keyI, keyR) = channel.initiator ? (x.publicKey, x.theirKey) : (x.theirKey, x.publicKey)
        let (nonceI, nonceR) = channel.initiator ? (x.nonce, x.theirNonce) : (x.theirNonce, x.nonce)
        x.secret = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonceI + nonceR, sharedInfo: Data("duet pair".utf8), outputByteCount: 32)
        let digest = sha256(keyI + keyR + nonceI + nonceR)
        let number = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let code = String(format: "%03d %03d", number / 1000, number % 1000)
        note = "Pairing with \(peer.name): code \(code)"
        onChange()
        confirm(peer, code) { [weak self, weak channel] yes in
            guard let self, let channel, let x = channel.exchange, let secret = x.secret else { return }
            if yes {
                x.confirmedHere = true
                channel.send(["t": "pairOK", "mac": base64(self.confirmation(secret, role: channel.initiator ? "I" : "R"))])
                self.finishPairing(channel)
            } else {
                channel.send(["t": "pairNo"]) { channel.close() }
            }
        }
    }

    private func finishPairing(_ channel: Channel) {
        guard let x = channel.exchange, x.confirmedHere, x.confirmedThere, let secret = x.secret, let peer = channel.peer else { return }
        let pairing = Pairing(peer: peer, key: secret)
        self.pairing = pairing
        refused = false
        note = nil
        onPaired(pairing)
        // The session starts on a new connection, with the new secret.
        sessionChannel?.close()
        channel.close()
        onChange()
    }

    private func confirmation(_ secret: SymmetricKey, role: String) -> [UInt8] {
        [UInt8](HMAC<SHA256>.authenticationCode(for: Data("duet pair ok \(role)".utf8), using: secret))
    }
}

/// One TCP connection to the other Mac: 2-byte length frames of JSON, in clear until `seal`, then
/// sealed. Protocol state for `Link` rides along.
@MainActor
private final class Channel {
    let connection: NWConnection
    let initiator: Bool
    var onReady: (Channel) -> Void = { _ in }
    var onFrame: (Channel, [String: Any]) -> Void = { _, _ in }
    var onClose: (Channel) -> Void = { _ in }

    var peer: Link.Peer?
    var nonce: [UInt8] = []
    var exchange: Link.Exchange?
    var udp: DatagramCrypto?
    var authenticated = false
    /// Opened while this Mac looked over the direct link; for a session, while both did.
    var direct = false

    private var keys: (send: SymmetricKey, receive: SymmetricKey)?
    private var sent: UInt64 = 0, received: UInt64 = 0
    private var closed = false

    init(_ connection: NWConnection, initiator: Bool) {
        self.connection = connection
        self.initiator = initiator
    }

    var isSealed: Bool { keys != nil }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.onReady(self)
                case .waiting, .failed, .cancelled: self.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        readFrame()
    }

    /// From now on every frame is sealed, both ways.
    func seal(send: SymmetricKey, receive: SymmetricKey) { keys = (send, receive) }

    func send(_ message: [String: Any], then: (() -> Void)? = nil) {
        guard !closed, let json = try? JSONSerialization.data(withJSONObject: message) else { return }
        var body = [UInt8](json)
        let length = body.count + (keys == nil ? 0 : 16)
        guard length <= 0xFFFF else { return }
        let header = [UInt8(length >> 8), UInt8(length & 0xFF)]
        if let keys {
            body = Seal.seal(body, key: keys.send, counter: sent, aad: header)
            sent += 1
        }
        connection.send(content: Data(header + body), completion: .contentProcessed { _ in
            if let then { MainActor.assumeIsolated { then() } }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose(self)
    }

    private func readFrame() {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard error == nil, let data, data.count == 2 else { return self.close() }
                let header = [UInt8](data)
                let length = Int(header[0]) << 8 | Int(header[1])
                guard length > 0 else { return self.close() }
                self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
                    MainActor.assumeIsolated {
                        guard let self, !self.closed else { return }
                        guard error == nil, let data, data.count == length else { return self.close() }
                        var body = [UInt8](data)
                        if let keys = self.keys {
                            guard let plain = Seal.open(body[...], key: keys.receive, counter: self.received, aad: header[...]) else { return self.close() }
                            self.received += 1
                            body = plain
                        }
                        guard let message = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] else { return self.close() }
                        self.onFrame(self, message)
                        if !self.closed { self.readFrame() }
                    }
                }
            }
        }
    }
}

private func randomBytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255) } }
private func sha256(_ bytes: [UInt8]) -> [UInt8] { [UInt8](SHA256.hash(data: bytes)) }
private func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }
private func bytes(_ value: Any?) -> [UInt8]? { (value as? String).flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) } }
