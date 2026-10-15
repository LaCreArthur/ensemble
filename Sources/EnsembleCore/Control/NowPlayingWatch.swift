import Foundation
import os

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

/// Reports the Now Playing state on the main queue: once at start, then on each change.
/// Since macOS 15.4 the system tells only its own programs what plays, so the built-in script runner
/// reads it, on the system's change notices, and prints one line per change; if a macOS update closes
/// that, the script ends and the watch reports nothing more.
public final class NowPlayingWatch: @unchecked Sendable {
    private static let script = """
        ObjC.import('Foundation');
        function run() {
          $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
          ObjC.bindFunction('MRMediaRemoteRegisterForNowPlayingNotifications', ['void', ['id']]);
          ObjC.bindFunction('exit', ['void', ['int']]);
          const R = $.NSClassFromString('MRNowPlayingRequest');
          const out = $.NSFileHandle.fileHandleWithStandardOutput;
          let last = null;
          const report = () => {
            const client = R.localNowPlayingPlayerPath.client;
            const line = JSON.stringify({ playing: !!R.localIsPlaying, app: client.isNil() ? null : client.bundleIdentifier.js });
            if (line !== last) { out.writeData($(line + '\\n').dataUsingEncoding($.NSUTF8StringEncoding)); last = line; }
          };
          $.MRMediaRemoteRegisterForNowPlayingNotifications($.NSOperationQueue.mainQueue.underlyingQueue);
          for (const name of ['kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification', 'kMRMediaRemoteNowPlayingApplicationDidChangeNotification'])
            $.NSNotificationCenter.defaultCenter.addObserverForNameObjectQueueUsingBlock(name, $(), $.NSOperationQueue.mainQueue, report);
          // Ensemble holds this script's input open: it closes when Ensemble quits or crashes, and the script ends.
          const input = $.NSFileHandle.fileHandleWithStandardInput;
          $.NSNotificationCenter.defaultCenter.addObserverForNameObjectQueueUsingBlock('NSFileHandleDataAvailableNotification', input, $.NSOperationQueue.mainQueue, () => {
            if (Number(input.availableData.length) === 0) $.exit(0);   // the bridge gives the length as text
            input.waitForDataInBackgroundAndNotify;
          });
          input.waitForDataInBackgroundAndNotify;
          report();
          for (;;) $.NSRunLoop.currentRunLoop.runModeBeforeDate($.NSDefaultRunLoopMode, $.NSDate.distantFuture);
        }
        """
    private let process = Process()
    private var buffer = Data()
    private var stopped = false

    public init(onChange: @escaping @Sendable (NowPlaying) -> Void) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Self.script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = Pipe()
        process.terminationHandler = { [weak self] process in
            guard self?.stopped == false else { return }
            Logger(subsystem: "com.lacrearthur.ensemble", category: "audio")
                .error("Now Playing watch ended (status \(process.terminationStatus)): takeover and the playing state are off")
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.read(data).forEach(onChange) }
        }
    }

    deinit { stop() }

    public func run() throws { try process.run() }

    public func stop() {
        stopped = true
        if process.isRunning { process.terminate() }
    }

    /// Takes the script's output; returns the states in it.
    private func read(_ data: Data) -> [NowPlaying] {
        buffer.append(data)
        var states: [NowPlaying] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            if let state = try? JSONDecoder().decode(NowPlaying.self, from: buffer[buffer.startIndex..<end]) { states.append(state) }
            buffer.removeSubrange(...end)
        }
        return states
    }
}
