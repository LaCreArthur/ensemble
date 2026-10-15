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
/// wins). Music or a video that starts on the other Mac does the same there, and pauses
/// this Mac's music: the newest one wins, as AirPods move to the device that starts playing.
/// While one Mac plays the other's sound, both Macs have one volume: the volume keys, Control
/// Center or the menu on either Mac set it, mute included; each output also has its own share of it,
/// set on its Mac. The other Mac's menu and media keys control the music: play/pause, tracks. A
/// Bluetooth output puts a Mac on standby (headphones: private listening) unless it is ticked as a
/// speaker. The slowest ticked output sets the delay, and a paired Mac always leaves room in it for
/// the other Mac, so the delay does not change when the other Mac comes or goes. While a Mac shares,
/// apps play to Ensemble's sound device when it is installed: it reports the delay as its latency,
/// so video waits for the sound; the app installs that device when the user asks. The microphone tune on either Mac aligns its outputs, then the other
/// Mac, as heard there. While a Mac shares, its capture and main output run all the time, without
/// keeping the Mac awake (the apps that play do), so the start of a sound is never lost; its other
/// outputs and the stream to the other Mac start with the sound and stop 5 minutes after it.
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
    /// Seconds this Mac's sound is heard later than its clock and devices say, measured by a tune
    /// across both Macs (0 on at least one of them).
    private var trim: Double { didSet { store.set(trim, forKey: "trim"); engine?.latencyTrim.value = Float(trim) } }
    /// The other Mac's lead (seconds) as it last said, so the delay is right before it connects.
    private var peerLead: Double { didSet { store.set(peerLead, forKey: "peerLead") } }

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
    /// The newest release, when it is newer than this app.
    private(set) var newRelease: (version: String, page: URL)?
    /// This Mac's own volume (0...1), the volume of both Macs while one plays the other's sound; setting it sets the Mac's volume.
    var mainVolume: Double = 1 { didSet { if abs(Double(volumeControl?.position ?? 1) - mainVolume) > 0.001 { volumeControl?.position = Float(mainVolume) } } }
    /// What the other Mac last said about itself; nil without a session.
    private(set) var peer: PeerState?
    /// True while this Mac plays the other Mac's sound.
    var isReceiving: Bool { if case .stream = running?.input { true } else { false } }

    struct PeerState: Equatable {
        /// `stream`: the Bonjour name of its sound stream, empty while it sends none.
        var on: Bool, since: Double, stream: String, playing: Bool, volume: Double, muted: Bool, canPlay: Bool, lead: Double, trim: Double
        init(_ m: [String: Any]) {
            on = m["on"] as? Bool ?? false
            since = m["since"] as? Double ?? 0
            stream = m["stream"] as? String ?? ""
            playing = m["playing"] as? Bool ?? false
            volume = m["volume"] as? Double ?? 1
            muted = m["muted"] as? Bool ?? false
            canPlay = m["canPlay"] as? Bool ?? false
            lead = m["lead"] as? Double ?? 0
            trim = m["trim"] as? Double ?? 0
        }
    }

    struct Guide: Equatable {
        /// `denied`: not allowed on the local network; `sharing`: on, and allowed to record this Mac's sound;
        /// `device`: the app's sound device is installed (video waits for the sound); `looking`: the user asked
        /// to find the other Mac.
        var denied = false, paired = false, sharing = false, device = true, looking = false
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
    /// While the other Mac shares and an app here has its output open, listens for that app's sound, to share it instead.
    private var watch: NowPlayingWatch?
    /// Media commands sent to this Mac's music app and not yet received by it.
    private var delivering = 0
    private var engine: Engine?
    private var sender: StreamSender?
    private var receiver: StreamReceiver?
    private var running: Config?
    /// The speakers' volume: they apply it themselves, and the other outputs get it as gain.
    private var mainVolumeControl: SystemVolume?
    /// Ensemble's sound device's volume while it exists: the volume keys set it, the speakers follow it.
    private var deviceVolume: SystemVolume?
    /// The volume the user sets.
    private var volumeControl: SystemVolume? { deviceVolume ?? mainVolumeControl }
    private var observers: [AnyObject] = []
    private var volumeObservers: [AnyObject] = []
    private var deviceVolumeObservers: [AnyObject] = []
    /// The last state sent to the other Mac, and in which session.
    private var sentState: (state: [String: AnyHashable], session: ObjectIdentifier)?
    private var remoteCommands: [(MPRemoteCommand, Any)] = []
    /// The volume both Macs last agreed on while this Mac plays the other's sound.
    private var sharedVolume: (volume: Double, muted: Bool)?
    private let log = Logger(subsystem: "com.lacrearthur.duet", category: "audio")
    /// Logs the stream's health while this Mac plays the other Mac's sound.
    private var healthTimer: Timer?
    /// Ends the pause of this Mac's music if the other Mac's tune never says it is done.
    private var otherTuning: Timer?
    /// Keeps App Nap away from the stream threads while sound plays.
    private var activity: NSObjectProtocol? { didSet { if let oldValue { ProcessInfo.processInfo.endActivity(oldValue) } } }

    /// Lead time the other Mac gets: while paired, the sound is delayed this much here, whether or not
    /// it plays there. With the first copy of both routes, 99.9% of packets come within 17 ms, but while
    /// Universal Control rebuilds its direct link (every few minutes when idle) both routes stall up to
    /// about 150 ms.
    static let networkDelay = 0.15
    /// Seconds from an app handing its sound to its output to that sound entering Ensemble's timeline:
    /// macOS's capture (about 23 ms) and the engine's cycle (about 62 ms with 512-frame buffers), as
    /// `duet-lab device-path` measures them. Part of the latency Ensemble's sound device reports.
    static let capturePath = 0.086
    static let holdTime: TimeInterval = 300

    init() {
        isOn = store.bool(forKey: "on")
        since = store.double(forKey: "since")
        chosenOutputs = Set(store.stringArray(forKey: "outputs") ?? ["BuiltInSpeakerDevice"])
        volumes = store.dictionary(forKey: "volumes") as? [String: Double] ?? [:]
        lags = store.dictionary(forKey: "lags") as? [String: Double] ?? [:]
        trim = store.double(forKey: "trim")
        peerLead = store.double(forKey: "peerLead")
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
        if link.pairing != nil || store.bool(forKey: "findOtherMac") { link.start() }
        log.notice("started; open at login: \(SMAppService.mainApp.status == .enabled, privacy: .public)")
        observers = DeviceEvents.observe { [weak self] in MainActor.assumeIsolated { self?.update() } }
        // Waking up, or the user opening the menu, is a reason to look for the other Mac again.
        let lookAgain: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.link.lookAgain() } }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: lookAgain))
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: lookAgain))
        // Sleep stops every device and a Core Audio restart deletes the capture: after either, the
        // engine starts again from scratch (it runs all day while this Mac shares).
        let rebuild: @Sendable () -> Void = { [weak self] in MainActor.assumeIsolated {
            self?.restart(nil, playing: false)
            self?.update()
        } }
        observers.append(DeviceEvents.observeRestart(rebuild))
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in rebuild() })
        monitor.onChange = { [weak self] _ in MainActor.assumeIsolated { self?.appsPlayingChanged() } }
        monitor.start()
        update()
        checkForUpdate()
        observers.append(Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForUpdate() }
        })
    }

    func volume(_ key: String) -> Double { volumes[key] ?? 1 }
    func setVolume(_ key: String, _ value: Double) { volumes[key] = value }

    /// Play/pause and tracks on the sharing Mac, from this Mac's menu or media keys.
    func control(_ command: MediaCommand) { link.send(["t": "media", "cmd": command.rawValue]) }

    func pair(with peer: Link.Peer) { link.pair(with: peer) }

    /// Starts looking for the other Mac; macOS then asks for local network access the first time.
    func findOtherMac() {
        store.set(true, forKey: "findOtherMac")
        link.start()
        update()
    }

    /// Installs the app's sound device. Core Audio then restarts, and the engine with it.
    func installDevice() {
        NSApp.activate()
        if !EnsembleDevice.install() { log.notice("sound device not installed") }
        update()
    }

    /// Asks GitHub for the latest release of Ensemble.
    private func checkForUpdate() {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/LaCreArthur/ensemble/releases/latest")!),
                  let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String, let page = (release["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let latest = String(tag.trimmingPrefix("v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            newRelease = latest.compare(current, options: .numeric) == .orderedDescending ? (latest, page) : nil
        }
    }

    static func openLocalNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }

    // MARK: Rules

    /// Brings the engine and the link in line with the settings, the devices and the other Mac.
    func update() {
        outputs = OutputDevice.all()
        let session = link.session
        let peer = session == nil ? nil : self.peer
        if isOn, let peer, let session, peer.on, (peer.since, session.peer.id) > (since, link.me.id) {
            isOn = false   // the other Mac was switched on later; this runs update() again
            return
        }
        let main = outputs.first(where: \.isBuiltIn) ?? outputs.first
        // The built-in speakers always drive the timing, silent if not ticked.
        let devices = [main].compactMap { $0 } + outputs.filter { $0.uid != main?.uid && chosenOutputs.contains($0.uid) }
        let localLead = main.flatMap { main in devices.map { Engine.lead(of: $0, lag: lag($0), main: main) }.max() } ?? 0
        let delay = link.pairing != nil ? max(localLead, Self.networkDelay + peerLead) : localLead
        let system = OutputDevice.defaultOutput()
        let headphones = self.headphones
        let sharing = isOn && !devices.isEmpty
        if !sharing, EnsembleDevice.isSystemOutput, let main { try? OutputDevice.setDefaultOutput(main) }   // before the device goes
        EnsembleDevice.setLatency(sharing ? Self.capturePath + delay + (main?.outputLatency ?? 0) + trim : nil)
        let device = EnsembleDevice.id
        if headphones == nil, isOn || peer?.on == true {
            if sharing, device != nil {
                if !EnsembleDevice.isSystemOutput { EnsembleDevice.makeSystemOutput() }
            } else if let system, let main, system.isBluetooth, system != main {
                // A ticked Bluetooth speaker plays through Ensemble; the Mac's own output and volume stay on its speakers.
                try? OutputDevice.setDefaultOutput(main)
            }
        }
        watchVolumes(device: device)
        mainVolume = Double(volumeControl?.position ?? 1)
        let wanted = monitor.isPlaying || hold != nil || isTuning
        var desired: Config?
        if !devices.isEmpty, headphones == nil {
            if isOn {
                desired = Config(outputs: devices.map(\.uid), delay: delay, input: .capture)
            } else if !isOn, let peer, let session, peer.on, !peer.stream.isEmpty {
                let input = Input.stream(name: peer.stream, session: ObjectIdentifier(session.crypto))
                desired = Config(outputs: devices.map(\.uid), delay: localLead, input: input)
            }
        }
        let playing = desired != nil && (desired?.input != .capture || wanted)
        if desired != running { restart(desired, playing: playing) }
        if let engine, engine.othersRunning != playing {
            log.notice("other outputs \(playing ? "start" : "stop", privacy: .public)")
            do { try engine.runOthers(playing) } catch { log.error("cannot start: \(String(describing: error), privacy: .public)") }
        }
        isPlaying = engine != nil && playing
        if isPlaying != (activity != nil) {
            activity = isPlaying ? ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Playing sound") : nil
        }
        updateSender(session: session, peerPlays: peer?.canPlay == true)
        updateWatch(wanted: !isOn && peer?.on == true && headphones == nil)

        let peerName = session?.peer.name ?? link.pairing?.peer.name ?? "the other Mac"
        let names = ListFormatter.localizedString(byJoining: outputs.filter { chosenOutputs.contains($0.uid) }.map(\.name)
            + (peer?.canPlay == true ? [peerName] : []))
        if isReceiving {
            status = "Playing the sound of \(peerName)"
        } else if let headphones, isOn || peer?.on == true {
            status = "Standby: \(headphones.name) counts as headphones. Tick it to use it as a speaker"
        } else if !isOn {
            status = "Off"
        } else if names.isEmpty {
            status = "Playing nowhere: tick an output"
        } else if engine == nil {
            status = "Cannot capture the sound"
        } else if !wanted {
            status = "Ready for sound on " + names
        } else {
            status = isTuning ? "Tuning: listening to each output…" : "Playing on " + names
        }
        otherMacStatus = otherMacText(peer: peer, session: session)
        guide = Guide(denied: link.denied, paired: link.pairing != nil, sharing: isOn && engine != nil,
                      device: !EnsembleDevice.needsInstall, looking: link.started)
        shareVolume()
        applyVolumes()
        updateNowPlaying()
        sendState(canPlay: !isOn && headphones == nil && !devices.isEmpty, lead: localLead + trim)
    }

    private func otherMacText(peer: PeerState?, session: Link.Session?) -> String {
        if link.denied { return "macOS does not let Ensemble look for your other Mac: allow it in Local Network settings." }
        if let note = link.note { return note }
        if !link.started { return "" }
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

    /// The system output when it is a Bluetooth device not ticked as a speaker: headphones, private listening.
    private var headphones: OutputDevice? {
        OutputDevice.defaultOutput().flatMap { $0.isBluetooth && !chosenOutputs.contains($0.uid) ? $0 : nil }
    }

    /// Seconds an output is heard after the latency its device reports, as the tune measured.
    private func lag(_ device: OutputDevice) -> Double { lags[device.uid] ?? 0 }

    private func restart(_ config: Config?, playing: Bool) {
        stopSender()
        receiver?.stop()
        receiver = nil
        for output in engine?.outputs ?? [] {
            let missed = output.missed.load(ordering: .relaxed)
            if missed > 0 { log.notice("\(output.device.name, privacy: .public) played \(missed) frames of silence: the delay was too short for it") }
        }
        engine?.stop()
        engine = nil
        healthTimer?.invalidate()
        healthTimer = nil
        running = config
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
        for output in engine.outputs { output.lag.value = Float(lag(output.device)) }
        engine.latencyTrim.value = Float(trim)
        do {
            try engine.start(othersRunning: playing)
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
        applyVolumes()
    }

    /// The stream to the other Mac runs while this Mac plays its captured sound and the other Mac plays along.
    private func updateSender(session: Link.Session?, peerPlays: Bool) {
        let wanted = isPlaying && running?.input == .capture && peerPlays && session != nil
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

    private func updateWatch(wanted: Bool) {
        if !wanted {
            watch?.stop()
            watch = nil
        } else if watch == nil {
            let watch = NowPlayingWatch { [weak self] in MainActor.assumeIsolated { self?.takeOver() } }
            do {
                try watch.run()
                self.watch = watch
            } catch {
                log.error("cannot watch Now Playing: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Music or a video started here while the other Mac shares: this Mac shares instead, and the other
    /// Mac's music pauses (sent before the switch, while the other Mac still shares and obeys media commands).
    private func takeOver() {
        guard !isOn, let peer, peer.on, headphones == nil else { return }
        if peer.playing { control(.pause) }
        log.notice("a sound started here: this Mac shares now")
        isOn = true
    }

    // MARK: The other Mac

    /// Tells the other Mac what it needs, whenever that changes.
    private func sendState(canPlay: Bool, lead: Double) {
        guard let session = link.session else { return sentState = nil }
        let state: [String: AnyHashable] = [
            "t": "state", "on": isOn, "since": since, "stream": sender?.name ?? "", "playing": monitor.isPlaying,
            "volume": mainVolume, "muted": volumeControl?.isMuted ?? false, "canPlay": canPlay, "lead": lead, "trim": trim,
        ]
        let id = ObjectIdentifier(session.crypto)
        guard sentState?.state != state || sentState?.session != id else { return }
        sentState = (state, id)
        link.send(state)
    }

    private func received(_ message: [String: Any]) {
        switch message["t"] as? String {
        case "state":
            let state = PeerState(message)
            peer = state
            if peerLead != state.lead { peerLead = state.lead }
            update()
        case "media":
            guard isOn, let command = (message["cmd"] as? String).flatMap(MediaCommand.init(rawValue:)) else { break }
            delivering += 1
            command.perform { [weak self] in MainActor.assumeIsolated { self?.delivering -= 1; self?.update() } }
        case "volume":
            guard isOn, let value = message["value"] as? Double else { break }
            mainVolume = max(0, min(1, value))
            if let muted = message["muted"] as? Bool { volumeControl?.isMuted = muted }
        case "tune":
            // The other Mac tunes: if this Mac shares, its music pauses meanwhile (30 s at most).
            let on = message["on"] as? Bool == true
            otherTuning?.invalidate()
            otherTuning = on ? Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isOn == true { self?.engine?.mainGain.value = 1 } }
            } : nil
            if isOn { engine?.mainGain.value = on ? 0 : 1 }
        case "click":
            if isOn, let engine { engine.injectClick(atFrame: engine.ring.writeIndex + Int(0.05 * engine.sampleRate)) }
        case "trim":
            guard let value = message["value"] as? Double else { break }
            trim = max(0, min(0.5, value))
            update()
        default:
            break
        }
    }

    /// While this Mac plays the other Mac's sound, Duet is its now-playing app: the media keys and
    /// Control Center control the music on the other Mac. Not while a command to this Mac's own music
    /// is on its way: the system gives it to the now-playing app of the moment, and the pause that comes
    /// with the other Mac taking sharing would reach Duet and pause the other Mac's music instead.
    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard isReceiving, delivering == 0, let name = link.session?.peer.name else {
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
        guard isReceiving, let peer, let control = volumeControl else { return sharedVolume = nil }
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

    /// Watches the speakers' volume and, while it exists, the volume of Ensemble's sound device (`device`),
    /// which starts at the speakers' volume and then leads it.
    private func watchVolumes(device: AudioObjectID?) {
        let builtIn = outputs.first(where: \.isBuiltIn)?.id
        if builtIn != mainVolumeControl?.device {
            mainVolumeControl = builtIn.map(SystemVolume.init(device:))
            volumeObservers = mainVolumeControl?.observe { [weak self] in MainActor.assumeIsolated { self?.update() } } ?? []
        }
        if device != deviceVolume?.device {
            deviceVolume = device.map(SystemVolume.init(device:))
            if let deviceVolume, let speakers = mainVolumeControl {
                deviceVolume.position = speakers.position
                deviceVolume.isMuted = speakers.isMuted
            }
            deviceVolumeObservers = deviceVolume?.observe { [weak self] in MainActor.assumeIsolated { self?.update() } } ?? []
        }
        guard let deviceVolume, let speakers = mainVolumeControl else { return }
        if abs(speakers.position - deviceVolume.position) > 0.001 { speakers.position = deviceVolume.position }
        if speakers.isMuted != deviceVolume.isMuted { speakers.isMuted = deviceVolume.isMuted }
    }

    /// The main output's device applies this Mac's volume itself; the others get it as gain. The other
    /// Mac applies the same volume itself (see `shareVolume`).
    private func applyVolumes() {
        guard let engine, !isTuning else { return }   // the tune sets every gain meanwhile
        let main = mainVolumeControl
        for (i, output) in engine.outputs.enumerated() {
            let uid = output.device.uid
            let own = Float(volume(uid))
            output.gain.value = chosenOutputs.contains(uid) ? own * own * (i == 0 ? 1 : main?.gain ?? 1) : 0
        }
        sender?.gain.value = 1
    }

    // MARK: Sync tuning

    /// Measures with the microphone when each output, then the other Mac, is heard, and corrects them
    /// (music pauses ~3 s per output). The other Mac is set to be heard together with this one here,
    /// where the listener sits.
    func tuneSync() {
        guard !isTuning, let mic = builtInMicrophone() else { return }
        isTuning = true
        update()
        guard let engine else { isTuning = false; return update() }
        let other = otherMacToTune(engine)
        link.send(["t": "tune", "on": true])
        Task {
            let results = await Task.detached { try? Calibration.run(engine, microphone: mic, other: other) }.value
            link.send(["t": "tune", "on": false])
            for output in engine.outputs.dropFirst() { lags[output.device.uid] = Double(output.lag.value) }
            let main = results?.first?.delay
            for r in results ?? [] {
                log.notice("tune: \(r.output, privacy: .public) heard \(((r.delay ?? .nan) - (main ?? .nan)) * 1000, format: .fixed(precision: 1)) ms after the main output, strength \(r.strength, format: .fixed(precision: 0))")
            }
            if other != nil, let results, results.count > engine.outputs.count, let main, let heard = results.last?.delay {
                // How much later the other Mac must be told its sound is heard than this Mac.
                let later = (peer?.trim ?? 0) - trim + heard - main
                trim = max(0, -later)
                link.send(["t": "trim", "value": max(0, later)])
            }
            isTuning = false
            update()
            let missed = results?.filter { $0.delay == nil }.map(\.output) ?? ["all outputs"]
            if !missed.isEmpty { status = "Not heard: " + ListFormatter.localizedString(byJoining: missed) }
        }
    }

    /// The other Mac as one more output to tune, while both Macs play one stream.
    private func otherMacToTune(_ engine: Engine) -> Calibration.OtherMac? {
        guard let name = link.session?.peer.name else { return nil }
        if let sender, peer?.canPlay == true {
            // This Mac shares: its clicks reach the other Mac through the stream.
            return Calibration.OtherMac(name: name, solo: { sender.gain.value = $0 ? 1 : 0 }) {
                engine.injectClick(atFrame: engine.ring.writeIndex + Int(0.05 * engine.sampleRate))
            }
        }
        guard isReceiving else { return nil }
        // The other Mac shares: it clicks when asked, and its clicks come here in its stream.
        let link = link
        return Calibration.OtherMac(name: name, solo: { engine.mainGain.value = $0 ? 1 : 0 }) {
            DispatchQueue.main.async { MainActor.assumeIsolated { link.send(["t": "click"]) } }
        }
    }
}
