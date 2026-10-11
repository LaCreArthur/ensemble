import AppKit
import CoreAudio
import DuetCore
import MediaPlayer
import Observation
import ServiceManagement
import SystemConfiguration
import os

/// The app's state, and the rules that run the audio engine and the link to the other Mac.
///
/// Rules: Duet runs on both Macs. The Mac where Duet is on shares its sound: every app's sound plays
/// on its ticked outputs and on the other Mac, all heard together; the other Mac plays along unless
/// its output is headphones. Turning Duet on on one Mac turns it off on the other (the later switch
/// wins). While one Mac plays the other's sound, both Macs have one volume: the volume keys, Control
/// Center or the menu on either Mac set it, mute included; each output also has its own share of it,
/// set on its Mac. The other Mac's menu and media keys control the music: play/pause, tracks. Headphones as a Mac's output put it on standby (private
/// listening). The capture runs only while some app plays sound, and for a while after, because
/// running audio keeps the Mac from sleeping.
@MainActor @Observable
final class Duet {
    // MARK: Remembered settings

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            since = Date().timeIntervalSince1970
            store.set(isOn, forKey: "on")
            if isOn, let main = outputs.first(where: \.isBuiltIn), OutputDevice.defaultOutput() != main {
                try? OutputDevice.setDefaultOutput(main)   // a click on Duet means "play on the speakers"
            }
            update()
        }
    }
    /// When Duet was last turned on or off here (seconds since 1970): between the two Macs, the later switch wins.
    private var since: Double { didSet { store.set(since, forKey: "since") } }
    /// Ticked outputs of this Mac (device UIDs).
    var chosenOutputs: Set<String> { didSet { store.set(Array(chosenOutputs), forKey: "outputs"); update() } }
    /// Per-output volume, 0...1, by device UID.
    var volumes: [String: Double] { didSet { store.set(volumes, forKey: "volumes"); applyVolumes() } }
    /// Measured sync corrections (seconds) by device UID.
    private var lags: [String: Double] { didSet { store.set(lags, forKey: "lags") } }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    // MARK: Live state

    let link: Link
    private(set) var outputs: [OutputDevice] = []
    private(set) var status = ""
    private(set) var otherMacStatus = ""
    private(set) var isPlaying = false
    private(set) var isTuning = false
    /// Where the first use stands, for the guide.
    private(set) var guide = Guide()
    /// This Mac's own volume (0...1), the volume of both Macs while one plays the other's sound; setting it sets the Mac's volume.
    var mainVolume: Double = 1 { didSet { if abs(Double(mainVolumeControl?.position ?? 1) - mainVolume) > 0.001 { mainVolumeControl?.position = Float(mainVolume) } } }
    /// What the other Mac last said about itself; nil without a session.
    private(set) var peer: PeerState?
    /// True while this Mac plays the other Mac's sound.
    var isReceiving: Bool { if case .stream = running?.input { true } else { false } }

    struct PeerState: Equatable {
        /// `stream`: the Bonjour name of its sound stream, empty while it sends none.
        var on: Bool, since: Double, stream: String, playing: Bool, volume: Double, muted: Bool, canPlay: Bool, lead: Double
        init(_ m: [String: Any]) {
            on = m["on"] as? Bool ?? false
            since = m["since"] as? Double ?? 0
            stream = m["stream"] as? String ?? ""
            playing = m["playing"] as? Bool ?? false
            volume = m["volume"] as? Double ?? 1
            muted = m["muted"] as? Bool ?? false
            canPlay = m["canPlay"] as? Bool ?? false
            lead = m["lead"] as? Double ?? 0
        }
    }

    struct Guide: Equatable {
        /// `denied`: not allowed on the local network; `playing`: sound plays on both Macs.
        var denied = false, found = false, paired = false, playing = false
    }

    private enum Input: Equatable {
        case capture
        case stream(name: String, session: ObjectIdentifier)
    }

    private struct Config: Equatable {
        var outputs: [String]   // device UIDs, main output first
        var delay: Double
        var input: Input
    }

    private let store = UserDefaults.standard
    private let monitor = PlaybackMonitor(excluding: [getpid()])
    /// Keeps the capture running for a while after the last app stops, so pauses do not restart it.
    private var hold: Timer?
    private var engine: Engine?
    private var sender: StreamSender?
    private var receiver: StreamReceiver?
    private var running: Config?
    private var mainVolumeControl: SystemVolume?
    private var observers: [AnyObject] = []
    private var volumeObservers: [AnyObject] = []
    /// The last state sent to the other Mac, and in which session.
    private var sentState: (state: [String: AnyHashable], session: ObjectIdentifier)?
    private var remoteCommands: [(MPRemoteCommand, Any)] = []
    /// The volume both Macs last agreed on while this Mac plays the other's sound.
    private var sharedVolume: (volume: Double, muted: Bool)?
    private let log = Logger(subsystem: "com.lacrearthur.duet", category: "audio")
    /// Logs the stream's health while this Mac plays the other Mac's sound.
    private var healthTimer: Timer?
    /// Keeps App Nap away from the stream threads while sound plays.
    private var activity: NSObjectProtocol? { didSet { if let oldValue { ProcessInfo.processInfo.endActivity(oldValue) } } }

    /// Lead time the other Mac gets: the sound is delayed this much here while it plays there. With the
    /// first copy of both routes, 99.9% of packets come within 17 ms, but while Universal Control rebuilds
    /// its direct link (every few minutes when idle) both routes stall up to about 150 ms.
    static let networkDelay = 0.15
    static let holdTime: TimeInterval = 300

    init() {
        isOn = store.bool(forKey: "on")
        since = store.double(forKey: "since")
        chosenOutputs = Set(store.stringArray(forKey: "outputs") ?? ["BuiltInSpeakerDevice"])
        volumes = store.dictionary(forKey: "volumes") as? [String: Double] ?? [:]
        lags = store.dictionary(forKey: "lags") as? [String: Double] ?? [:]
        var id = store.string(forKey: "deviceID") ?? ""
        if id.isEmpty {
            id = UUID().uuidString
            store.set(id, forKey: "deviceID")
            try? SMAppService.mainApp.register()   // first launch: open at login
        }
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? Host.current().localizedName ?? "Mac"
        link = Link(me: Link.Peer(id: id, name: name), pairing: PairingStore.load())
        link.onPaired = { PairingStore.save($0) }
        link.confirm = { peer, code, reply in
            DispatchQueue.main.async {
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = "Pair with \(peer.name)?"
                alert.informativeText = "Pair only if \(peer.name) shows the same code:\n\n\(code)"
                alert.addButton(withTitle: "Pair")
                alert.addButton(withTitle: "Cancel")
                reply(alert.runModal() == .alertFirstButtonReturn)
            }
        }
        link.onChange = { [weak self] in
            guard let self else { return }
            if link.session == nil { peer = nil }
            update()
        }
        link.onMessage = { [weak self] in self?.received($0) }
        link.start()
        log.notice("started; open at login: \(SMAppService.mainApp.status == .enabled, privacy: .public)")
        observers = DeviceEvents.observe { [weak self] in MainActor.assumeIsolated { self?.update() } }
        // Waking up, or the user opening the menu, is a reason to look for the other Mac again.
        let lookAgain: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.link.lookAgain() } }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: lookAgain))
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: lookAgain))
        monitor.onChange = { [weak self] _ in MainActor.assumeIsolated { self?.appsPlayingChanged() } }
        monitor.start()
        update()
    }

    func volume(_ key: String) -> Double { volumes[key] ?? 1 }
    func setVolume(_ key: String, _ value: Double) { volumes[key] = value }

    /// Play/pause and tracks on the sharing Mac, from this Mac's menu or media keys.
    func control(_ command: MediaCommand) { link.send(["t": "media", "cmd": command.rawValue]) }

    func pair(with peer: Link.Peer) { link.pair(with: peer) }

    static func openLocalNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }

    // MARK: Rules

    /// Brings the engine and the link in line with the settings, the devices and the other Mac.
    func update() {
        outputs = OutputDevice.all().filter { !$0.isPersonal }
        watchMainVolume()
        mainVolume = Double(mainVolumeControl?.position ?? 1)
        let headphones = OutputDevice.defaultOutput()?.isPersonal ?? false
        let session = link.session
        let peer = session == nil ? nil : self.peer
        if isOn, let peer, let session, peer.on, (peer.since, session.peer.id) > (since, link.me.id) {
            isOn = false   // the other Mac was switched on later; this runs update() again
            return
        }
        let main = outputs.first(where: \.isBuiltIn) ?? outputs.first
        // The built-in speakers always drive the timing, silent if not ticked.
        let devices = [main].compactMap { $0 } + outputs.filter { $0.uid != main?.uid && chosenOutputs.contains($0.uid) }
        let localLead = devices.map { max(0, lags[$0.uid] ?? 0) }.max() ?? 0
        let wanted = monitor.isPlaying || hold != nil || isTuning
        var desired: Config?
        if !devices.isEmpty, !headphones {
            if isOn, wanted {
                let delay = peer?.canPlay == true ? max(localLead, Self.networkDelay + (peer?.lead ?? 0)) : localLead
                desired = Config(outputs: devices.map(\.uid), delay: delay, input: .capture)
            } else if !isOn, let peer, let session, peer.on, !peer.stream.isEmpty {
                let input = Input.stream(name: peer.stream, session: ObjectIdentifier(session.crypto))
                desired = Config(outputs: devices.map(\.uid), delay: localLead, input: input)
            }
        }
        if desired != running { restart(desired) }
        updateSender(session: session, peerPlays: peer?.canPlay == true)

        let peerName = session?.peer.name ?? link.pairing?.peer.name ?? "the other Mac"
        let names = ListFormatter.localizedString(byJoining: outputs.filter { chosenOutputs.contains($0.uid) }.map(\.name)
            + (peer?.canPlay == true ? [peerName] : []))
        if isReceiving {
            status = "Playing the sound of \(peerName)"
        } else if headphones && (isOn || peer?.on == true) {
            status = "Standby: headphones are this Mac's output"
        } else if !isOn {
            status = "Off"
        } else if names.isEmpty {
            status = "Playing nowhere: tick an output"
        } else if !wanted {
            status = "Ready for sound on " + names
        } else if engine == nil {
            status = "Cannot capture the sound"
        } else {
            status = isTuning ? "Tuning: listening to each output…" : "Playing on " + names
        }
        isPlaying = engine != nil
        otherMacStatus = otherMacText(peer: peer, session: session)
        guide = Guide(denied: link.denied, found: !link.nearby.isEmpty || session != nil, paired: link.pairing != nil,
                      playing: isReceiving || engine != nil && peer?.canPlay == true)
        shareVolume()
        applyVolumes()
        updateNowPlaying()
        sendState(canPlay: !isOn && !headphones && !devices.isEmpty, lead: localLead)
    }

    private func otherMacText(peer: PeerState?, session: Link.Session?) -> String {
        if link.denied { return "macOS does not let Ensemble look for your other Mac: allow it in Local Network settings." }
        if let note = link.note { return note }
        guard let pairing = link.pairing else {
            return link.nearby.isEmpty ? "Open Ensemble on your other Mac to pair it." : ""
        }
        let name = pairing.peer.name
        guard session != nil, let peer else {
            return link.nearby.contains { $0.id == pairing.peer.id } ? "Connecting to \(name)…" : "Looking for \(name)…"
        }
        if peer.on { return "\(name) shares its sound." }
        if isOn { return peer.canPlay ? "\(name) plays along." : "\(name) is on headphones." }
        return "\(name) is ready."
    }

    private func restart(_ config: Config?) {
        stopSender()
        receiver?.stop()
        receiver = nil
        engine?.stop()
        engine = nil
        healthTimer?.invalidate()
        healthTimer = nil
        running = config
        activity = nil
        guard let config else { return log.notice("stopped") }
        let devices = config.outputs.compactMap { uid in outputs.first { $0.uid == uid } }
        let input: Engine.Input
        switch config.input {
        case .capture:
            input = .captureAllExcept([getpid()])
        case .stream(let name, _):
            guard let session = link.session else {
                running = nil
                return
            }
            let receiver = StreamReceiver(crypto: session.crypto, name: name)
            receiver.start()
            self.receiver = receiver
            input = .network(receiver)
        }
        let engine = Engine(input: input, outputs: devices, delaySeconds: config.delay)
        for output in engine.outputs { output.lag.value = Float(lags[output.device.uid] ?? 0) }
        do {
            try engine.start()
        } catch {
            log.error("cannot start: \(String(describing: error), privacy: .public)")
            receiver?.stop()
            receiver = nil
            running = nil
            return
        }
        self.engine = engine
        log.notice("playing \(self.receiver == nil ? "this Mac's sound" : "the other Mac's sound", privacy: .public) on \(devices.count) outputs, delay \(config.delay, format: .fixed(precision: 3)) s")
        if let receiver {
            healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self, weak receiver] _ in
                guard let receiver else { return }
                let s = receiver.takeStats()
                MainActor.assumeIsolated {
                    self?.log.notice("""
                        stream: routes \(s.routes), packets \(s.packets) resent \(s.resent) concealed \(s.concealed) frames, jumps \(s.jumps), \
                        least margin \(s.minMargin * 1000, format: .fixed(precision: 1)) ms, error \(s.error * 1000, format: .fixed(precision: 2)) ms, \
                        round trip \(s.roundTrip * 1000, format: .fixed(precision: 1)) ms
                        """)
                }
            }
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Playing sound")
        applyVolumes()
    }

    /// The stream to the other Mac runs while this Mac captures its sound and the other Mac plays along.
    private func updateSender(session: Link.Session?, peerPlays: Bool) {
        let wanted = running?.input == .capture && peerPlays && session != nil
        if !wanted || sender?.crypto !== session?.crypto { stopSender() }
        guard wanted, sender == nil, let engine, let session, let sender = try? StreamSender(engine: engine, crypto: session.crypto) else { return }
        sender.start()
        self.sender = sender
        applyVolumes()
    }

    private func stopSender() {
        sender?.stop()
        sender = nil
    }

    private func appsPlayingChanged() {
        hold?.invalidate()
        hold = monitor.isPlaying || engine == nil ? nil : Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hold = nil; self?.update() }
        }
        update()
    }

    // MARK: The other Mac

    /// Tells the other Mac what it needs, whenever that changes.
    private func sendState(canPlay: Bool, lead: Double) {
        guard let session = link.session else { return sentState = nil }
        let state: [String: AnyHashable] = [
            "t": "state", "on": isOn, "since": since, "stream": sender?.name ?? "", "playing": monitor.isPlaying,
            "volume": mainVolume, "muted": mainVolumeControl?.isMuted ?? false, "canPlay": canPlay, "lead": lead,
        ]
        let id = ObjectIdentifier(session.crypto)
        guard sentState?.state != state || sentState?.session != id else { return }
        sentState = (state, id)
        link.send(state)
    }

    private func received(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "state":
            peer = PeerState(message)
            update()
        case "media":
            if isOn, let command = (message["cmd"] as? String).flatMap(MediaCommand.init(rawValue:)) { command.perform() }
        case "volume":
            guard isOn, let value = message["value"] as? Double else { break }
            mainVolume = max(0, min(1, value))
            if let muted = message["muted"] as? Bool { mainVolumeControl?.isMuted = muted }
        default:
            break
        }
    }

    /// While this Mac plays the other Mac's sound, Duet is its now-playing app: the media keys and
    /// Control Center control the music on the other Mac.
    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard isReceiving, let name = link.session?.peer.name else {
            guard !remoteCommands.isEmpty else { return }
            for (command, target) in remoteCommands { command.removeTarget(target) }
            remoteCommands = []
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        if remoteCommands.isEmpty {
            let commands = MPRemoteCommandCenter.shared()
            let pairs: [(MPRemoteCommand, MediaCommand)] = [
                (commands.togglePlayPauseCommand, .playPause), (commands.playCommand, .play), (commands.pauseCommand, .pause),
                (commands.nextTrackCommand, .next), (commands.previousTrackCommand, .previous),
            ]
            remoteCommands = pairs.map { command, media in
                (command, command.addTarget { [weak self] _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.control(media) } }
                    return .success
                })
            }
        }
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "Sound of \(name)", MPMediaItemPropertyArtist: "Ensemble"]
        center.playbackState = peer?.playing == true ? .playing : .paused
    }

    // MARK: Volume

    /// One volume while this Mac plays the other's sound: a change there shows here, and a change
    /// here (keys, Control Center, menu) goes there.
    private func shareVolume() {
        guard isReceiving, let peer, let control = mainVolumeControl else { return sharedVolume = nil }
        let mine = (volume: mainVolume, muted: control.isMuted)
        if sharedVolume?.volume != peer.volume || sharedVolume?.muted != peer.muted {
            sharedVolume = (peer.volume, peer.muted)
            mainVolume = peer.volume
            if mine.muted != peer.muted { control.isMuted = peer.muted }
        } else if abs(mine.volume - peer.volume) > 0.01 || mine.muted != peer.muted {
            sharedVolume = mine
            self.peer?.volume = mine.volume
            self.peer?.muted = mine.muted
            link.send(["t": "volume", "value": mine.volume, "muted": mine.muted])
        }
    }

    private func watchMainVolume() {
        let device = outputs.first(where: \.isBuiltIn)?.id
        guard device != mainVolumeControl?.device else { return }
        mainVolumeControl = device.map(SystemVolume.init(device:))
        volumeObservers = mainVolumeControl?.observe { [weak self] in MainActor.assumeIsolated { self?.update() } } ?? []
    }

    /// The main output's device applies this Mac's volume itself; the others get it as gain. The other
    /// Mac applies the same volume itself (see `shareVolume`).
    private func applyVolumes() {
        guard let engine else { return }
        let main = mainVolumeControl
        for (i, output) in engine.outputs.enumerated() {
            let uid = output.device.uid
            let own = Float(volume(uid))
            output.gain.value = chosenOutputs.contains(uid) ? own * own * (i == 0 ? 1 : main?.gain ?? 1) : 0
        }
        // Silent there while tuning: the clicks are for this Mac's microphone.
        sender?.gain.value = isTuning ? 0 : 1
    }

    // MARK: Sync tuning

    /// Measures with the microphone when each output is heard and corrects it (music pauses ~2 s per output).
    func tuneSync() {
        guard !isTuning, let mic = builtInMicrophone() else { return }
        isTuning = true
        update()
        guard let engine else { isTuning = false; return update() }
        Task {
            let results = await Task.detached { try? Calibration.run(engine, microphone: mic) }.value
            for output in engine.outputs.dropFirst() { lags[output.device.uid] = Double(output.lag.value) }
            isTuning = false
            update()
            let missed = results?.filter { $0.delay == nil }.map(\.output) ?? ["all outputs"]
            if !missed.isEmpty { status = "Not heard: " + ListFormatter.localizedString(byJoining: missed) }
        }
    }
}
