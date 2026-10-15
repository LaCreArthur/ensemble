import AVFoundation
import MediaPlayer

/// Test double for a music app: plays a 30 Hz tone at -60 dBFS (a level meter hears it, laptop speakers
/// cannot play it), publishes now-playing info and logs remote commands. A pause stops the sound but
/// keeps the output open, playing zeros, as browsers and Electron apps do; `resumeAfter` seconds after its
/// last pause it plays again by itself, as a user pressing play.
enum NowPlayingStandIn {
    static func run(seconds: Double, resumeAfter: Double?) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))!
        tone.frameLength = tone.frameCapacity
        for c in 0..<Int(format.channelCount) {
            for i in 0..<Int(tone.frameLength) { tone.floatChannelData![c][i] = 0.001 * sin(2 * .pi * 30 * Float(i) / Float(format.sampleRate)) }
        }
        try! engine.start()
        let info = MPNowPlayingInfoCenter.default()
        let t0 = Date()
        func say(_ s: String) { print(String(format: "%.1f s: %@", Date().timeIntervalSince(t0), s)) }
        func play() {
            player.scheduleBuffer(tone, at: nil, options: .loops)
            player.play()
            info.nowPlayingInfo = [MPMediaItemPropertyTitle: "Ensemble test", MPMediaItemPropertyArtist: "Ensemble",
                                   MPNowPlayingInfoPropertyPlaybackRate: 1.0, MPMediaItemPropertyPlaybackDuration: 120.0,
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0]
            info.playbackState = .playing
            say("playing")
        }
        var pauses = 0
        func pause() {
            player.stop()   // the engine keeps running: the output stays open with zeros
            info.playbackState = .paused
            say("paused")
            pauses += 1
            let pause = pauses
            if let resumeAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + resumeAfter) { if pauses == pause, !player.isPlaying { play() } }
            }
        }
        let center = MPRemoteCommandCenter.shared()
        let commands: [(String, MPRemoteCommand)] = [("play", center.playCommand), ("pause", center.pauseCommand),
                                                     ("playPause", center.togglePlayPauseCommand),
                                                     ("next", center.nextTrackCommand), ("previous", center.previousTrackCommand)]
        for (name, command) in commands {
            command.isEnabled = true
            command.addTarget { _ in
                say("RECEIVED \(name)")
                if name == "pause" || name == "playPause" && player.isPlaying { pause() } else if name == "play" { play() }
                return .success
            }
        }
        play()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        info.playbackState = .stopped
        info.nowPlayingInfo = nil
        player.stop()
        engine.stop()
        say("stopped")
    }
}
