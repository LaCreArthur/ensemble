import AVFoundation
import MediaPlayer

/// Test double for a music app: plays silence, publishes now-playing info, logs remote commands.
enum NowPlayingStandIn {
    static func run(seconds: Double) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))!
        silence.frameLength = silence.frameCapacity
        try! engine.start()
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()

        let center = MPRemoteCommandCenter.shared()
        let commands: [(String, MPRemoteCommand)] = [("play", center.playCommand), ("pause", center.pauseCommand),
                                                     ("playPause", center.togglePlayPauseCommand),
                                                     ("next", center.nextTrackCommand), ("previous", center.previousTrackCommand)]
        for (name, command) in commands {
            command.isEnabled = true
            command.addTarget { _ in print("RECEIVED \(name)"); return .success }
        }
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: "Duet test", MPMediaItemPropertyArtist: "Duet",
                               MPNowPlayingInfoPropertyPlaybackRate: 1.0, MPMediaItemPropertyPlaybackDuration: 120.0,
                               MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0]
        info.playbackState = .playing
        print("now playing as Duet test")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        info.playbackState = .stopped
        info.nowPlayingInfo = nil
        player.stop()
        engine.stop()
    }
}
