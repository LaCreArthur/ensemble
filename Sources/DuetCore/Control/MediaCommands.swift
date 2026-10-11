import Foundation

/// Play/pause and track commands for whatever app is playing on this Mac (Spotify, Music, a browser),
/// sent through the system's now-playing service, like the keyboard's media keys.
/// The system checks the sender's code signature after the call returns, so the sending process must
/// stay alive for a moment after sending (an app does; a one-shot tool must wait).
public enum MediaCommand: String, CaseIterable, Sendable {
    case play, pause, playPause, next, previous

    private var code: Int32 {
        switch self {
        case .play: 0
        case .pause: 1
        case .playPause: 2
        case .next: 4
        case .previous: 5
        }
    }

    private typealias Send = @convention(c) (Int32, CFDictionary?) -> Bool
    private static let send: Send? = {
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
              let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else { return nil }
        return unsafeBitCast(pointer, to: Send.self)
    }()

    @discardableResult
    public func perform() -> Bool { Self.send?(code, nil) ?? false }
}
