import Foundation

/// Play/pause and track commands for whatever app is playing on this Mac (Spotify, Music, a browser),
/// sent through the system's now-playing service, like the keyboard's media keys.
/// The system delivers it later, to whichever app is the now-playing one at that moment (a few hundred
/// ms, measured), then calls back; the sending process must stay alive until then.
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

    private typealias Send = @convention(c) (Int32, CFDictionary?, DispatchQueue, @escaping @convention(block) (CFArray?) -> Void) -> Void
    private static let send: Send? = {
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
              let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommandWithReply" as CFString) else { return nil }
        return unsafeBitCast(pointer, to: Send.self)
    }()

    /// Calls `delivered` on the main queue once the now-playing app has received the command.
    public func perform(delivered: @escaping @Sendable () -> Void) {
        guard let send = Self.send else { return DispatchQueue.main.async(execute: delivered) }
        send(code, nil, .main) { _ in delivered() }
    }
}
