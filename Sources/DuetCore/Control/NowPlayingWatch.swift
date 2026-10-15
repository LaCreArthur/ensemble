import Foundation

/// The app the system shows in Control Center's Now Playing, and whether it plays.
public struct NowPlaying: Decodable, Equatable, Sendable {
    public var playing: Bool
    public var app: String?

    public init(playing: Bool, app: String?) {
        self.playing = playing
        self.app = app
    }
}

/// Tells when an app other than `own` starts playing: a change to playing, never a state already there
/// when the watch begins (an app that ignored a pause must not take sharing back).
public struct MediaStart {
    public let own: String?
    private var last: NowPlaying?

    public init(own: String?) { self.own = own }

    public mutating func feed(_ now: NowPlaying) -> Bool {
        defer { last = now }
        guard let last, now.playing, now.app != own else { return false }
        return !last.playing || last.app != now.app
    }
}

/// Calls `onStart` on the main queue when an app other than this one starts playing on this Mac.
/// Since macOS 15.4 the system tells only its own programs what plays, so the built-in script runner
/// reads it and prints one line per change; if a macOS update closes that, the watch tells nothing.
public final class NowPlayingWatch: @unchecked Sendable {
    private static let script = """
        function run() {
          $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
          const R = $.NSClassFromString('MRNowPlayingRequest');
          const out = $.NSFileHandle.fileHandleWithStandardOutput;
          let last = null;
          for (;;) {
            const client = R.localNowPlayingPlayerPath.client;
            const line = JSON.stringify({ playing: !!R.localIsPlaying, app: client.isNil() ? null : client.bundleIdentifier.js });
            if (line !== last) { out.writeData($(line + '\\n').dataUsingEncoding($.NSUTF8StringEncoding)); last = line; }
            delay(0.25);
          }
        }
        """
    private let process = Process()
    private var start: MediaStart
    private var buffer = Data()

    public init(onStart: @escaping @Sendable () -> Void) {
        start = MediaStart(own: Bundle.main.bundleIdentifier)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Self.script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { if self?.read(data) == true { onStart() } }
        }
    }

    deinit { stop() }

    public func run() throws { try process.run() }

    public func stop() { if process.isRunning { process.terminate() } }

    /// Takes the script's output; true when a line in it is a start.
    private func read(_ data: Data) -> Bool {
        buffer.append(data)
        var started = false
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(...end)
            if let now = try? JSONDecoder().decode(NowPlaying.self, from: line), start.feed(now) { started = true }
        }
        return started
    }
}
