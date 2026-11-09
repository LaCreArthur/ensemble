import os

/// What a Mac does, from its switch, its system output and what the other Mac said. The app derives it
/// on every change (it never stores it as truth), and the engine, the status line and the log read it.
public enum Role: Equatable, Sendable, CustomStringConvertible {
    /// Neither Mac shares.
    case off
    /// A Mac shares, and this Mac's system output is Bluetooth not ticked as a speaker: headphones,
    /// private listening; nothing plays through Ensemble here.
    case standby
    /// This Mac shares its apps' sound.
    case sharing
    /// The other Mac shares; `stream` is the Bonjour name of its sound stream, empty while it sends none.
    case receiving(stream: String)

    public init(on: Bool, headphones: Bool, peerOn: Bool, peerStream: String) {
        self = if headphones && (on || peerOn) { .standby }
            else if on { .sharing }
            else if peerOn { .receiving(stream: peerStream) }
            else { .off }
    }

    /// Of two Macs switched on, the one switched on later shares (equal times: the larger ID).
    public static func yields(since: Double, id: String, to peerSince: Double, _ peerID: String) -> Bool {
        (peerSince, peerID) > (since, id)
    }

    public var description: String {
        switch self {
        case .off: "off"
        case .standby: "standby"
        case .sharing: "sharing"
        case .receiving(let stream): stream.isEmpty ? "receiving (no stream yet)" : "receiving \(stream)"
        }
    }
}

extension Logger {
    /// Ensemble's log, by category: `/usr/bin/log show --predicate 'subsystem == "com.lacrearthur.ensemble"'`.
    public static func ensemble(_ category: String) -> Logger { Logger(subsystem: "com.lacrearthur.ensemble", category: category) }
}
