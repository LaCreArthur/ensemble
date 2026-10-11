import AppKit
import CoreAudio
import DuetCore
import Observation
import ServiceManagement
import SystemConfiguration

/// The app's state, and the rules that run the audio engine and the link to the other Mac.
///
/// Rules: while Duet is on, every app's sound plays on the ticked outputs of this Mac and on the
/// chosen other Mac, all heard together. Headphones as the Mac's output put Duet on standby (private
/// listening). The Mac's own volume (keys, Control Center) is the main volume for every output;
/// each output also has its own volume. The capture runs only while some app plays sound, and for a
/// while after, because a running capture keeps the Mac from sleeping.
@MainActor @Observable
final class Duet {
    // MARK: Remembered settings

    var isOn: Bool {
        didSet {
            store.set(isOn, forKey: "on")
            if isOn && !oldValue, let main = outputs.first(where: \.isBuiltIn), OutputDevice.defaultOutput() != main {
                try? OutputDevice.setDefaultOutput(main)   // a click on Duet means "play on the speakers"
            }
            update()
        }
    }
    /// Ticked outputs of this Mac (device UIDs).
    var chosenOutputs: Set<String> { didSet { store.set(Array(chosenOutputs), forKey: "outputs"); update() } }
    /// The other Mac's receiver ID; never chosen automatically.
    var otherMacID: String? {
        didSet {
            store.set(otherMacID, forKey: "otherMac")
            store.set(receivers.first { $0.id == otherMacID }?.name, forKey: "otherMacName")
            update()
        }
    }
    /// Per-output volume, 0...1, by device UID; the other Mac's is under `Duet.other`.
    var volumes: [String: Double] { didSet { store.set(volumes, forKey: "volumes"); applyVolumes() } }
    /// Measured sync corrections (seconds) by device UID.
    private var lags: [String: Double] { didSet { store.set(lags, forKey: "lags") } }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
    }

    static let other = "other-mac"

    // MARK: Live state

    private(set) var outputs: [OutputDevice] = []
    private(set) var receivers: [ReceiverBrowser.Receiver] = []
    private(set) var status = ""
    private(set) var otherMacStatus = ""
    private(set) var isPlaying = false
    private(set) var isTuning = false
    /// The Mac's own volume (0...1); setting it sets the Mac's volume.
    var mainVolume: Double = 1 { didSet { if abs(Double(mainVolumeControl?.position ?? 1) - mainVolume) > 0.001 { mainVolumeControl?.position = Float(mainVolume) } } }
    var rememberedOtherMacName: String? { store.string(forKey: "otherMacName") }

    private struct Config: Equatable {
        var outputs: [String]          // device UIDs, main output first
        var other: ReceiverBrowser.Receiver?
        var delay: Double
    }

    private let store = UserDefaults.standard
    private let browser = ReceiverBrowser()
    private let monitor = PlaybackMonitor(excluding: [getpid()])
    /// Keeps the capture running for a while after the last app stops, so pauses do not restart it.
    private var hold: Timer?
    private var engine: CaptureEngine?
    private var sender: AirPlaySender?
    private var running: Config?
    private var mainVolumeControl: SystemVolume?
    private var observers: [AnyObject] = []
    private var volumeObservers: [AnyObject] = []
    private var retry: Timer?
    private let remote: RemoteServer

    /// Lead time the other Mac gets: the sound is delayed this much on this Mac while it plays there.
    static let networkDelay = 0.3
    static let holdTime: TimeInterval = 300

    init() {
        isOn = store.bool(forKey: "on")
        chosenOutputs = Set(store.stringArray(forKey: "outputs") ?? ["BuiltInSpeakerDevice"])
        otherMacID = store.string(forKey: "otherMac")
        volumes = store.dictionary(forKey: "volumes") as? [String: Double] ?? [:]
        lags = store.dictionary(forKey: "lags") as? [String: Double] ?? [:]
        var key = store.string(forKey: "remoteKey") ?? ""
        if key.isEmpty {
            key = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            store.set(key, forKey: "remoteKey")
        }
        remote = RemoteServer(key: key)
        observers = DeviceEvents.observe { [weak self] in MainActor.assumeIsolated { self?.update() } }
        browser.onChange = { [weak self] list in
            guard let self else { return }
            receivers = list
            if let name = list.first(where: { $0.id == self.otherMacID })?.name { store.set(name, forKey: "otherMacName") }
            update()
        }
        browser.start()
        monitor.onChange = { [weak self] _ in MainActor.assumeIsolated { self?.appsPlayingChanged() } }
        monitor.start()
        remote.handle = { [weak self] action, parameters in self?.remoteCommand(action, parameters) ?? [:] }
        try? remote.start()
        update()
    }

    // MARK: Remote (the web page the other Mac opens)

    /// The link to open once in Safari on the other Mac.
    var remoteLink: String {
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } ?? "localhost"
        return remote.link(host: host)
    }

    func copyRemoteLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(remoteLink, forType: .string)
    }

    private func remoteCommand(_ action: String, _ parameters: [String: String]) -> [String: Any] {
        switch action {
        case "playPause", "next", "previous": MediaCommand(rawValue: action)?.perform()
        case "on": isOn = true
        case "off": isOn = false
        case "volume":
            if let id = parameters["id"], let value = parameters["value"].flatMap(Double.init) {
                if id == "main" { mainVolume = max(0, min(1, value)) } else { setVolume(id, max(0, min(1, value))) }
            }
        default: break
        }
        var volumes: [[String: Any]] = [["id": "main", "name": "Main volume", "value": mainVolume]]
        for output in outputs where chosenOutputs.contains(output.uid) {
            volumes.append(["id": output.uid, "name": output.name, "value": volume(output.uid)])
        }
        if otherMacID != nil {
            let name = receivers.first { $0.id == otherMacID }?.name ?? rememberedOtherMacName ?? "Other Mac"
            volumes.append(["id": Self.other, "name": name, "value": volume(Self.other)])
        }
        let other = otherMacStatus.isEmpty ? "" : " · Other Mac: " + otherMacStatus
        return ["on": isOn, "status": status + other, "volumes": volumes]
    }

    func volume(_ key: String) -> Double { volumes[key] ?? 1 }
    func setVolume(_ key: String, _ value: Double) { volumes[key] = value }

    // MARK: Rules

    /// Brings the engine and the link in line with the settings and the devices present now.
    func update() {
        outputs = OutputDevice.all().filter { !$0.isPersonal }
        watchMainVolume()
        let headphones = OutputDevice.defaultOutput()?.isPersonal ?? false
        let wanted = monitor.isPlaying || hold != nil || isTuning
        var desired: Config?
        if isOn, !headphones, wanted, let main = outputs.first(where: \.isBuiltIn) ?? outputs.first {
            // The built-in speakers always drive the timing, silent if not ticked.
            let extra = outputs.filter { $0.uid != main.uid && chosenOutputs.contains($0.uid) }
            let other = receivers.first { $0.id == otherMacID }
            let localDelay = ([main] + extra).map { max(0, lags[$0.uid] ?? 0) }.max() ?? 0
            desired = Config(outputs: [main.uid] + extra.map(\.uid), other: other, delay: other == nil ? localDelay : Self.networkDelay)
        }
        if desired != running { restart(desired) }

        let other = receivers.first { $0.id == otherMacID }
        let names = ListFormatter.localizedString(byJoining: outputs.filter { chosenOutputs.contains($0.uid) }.map(\.name) + [other?.name].compactMap { $0 })
        if !isOn {
            status = "Off"
        } else if headphones {
            status = "Standby: headphones are this Mac's output"
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
        if otherMacID == nil || !isOn || headphones {
            otherMacStatus = ""
        } else if other == nil {
            otherMacStatus = "Not on the network"
        } else if sender == nil {
            otherMacStatus = ""
        }
        applyVolumes()
    }

    private func restart(_ config: Config?) {
        retry?.invalidate()
        sender?.stop()
        sender = nil
        engine?.stop()
        engine = nil
        running = config
        guard let config else { return }
        let devices = config.outputs.compactMap { uid in outputs.first { $0.uid == uid } }
        let engine = CaptureEngine(source: .allExcept([getpid()]), outputs: devices, delaySeconds: config.delay)
        for output in engine.outputs { output.lag.value = Float(lags[output.device.uid] ?? 0) }
        do {
            try engine.start()
        } catch {
            running = nil
            return
        }
        self.engine = engine
        if let other = config.other {
            let sender = AirPlaySender(endpoint: other.endpoint, capture: engine)
            sender.onState = { [weak self, weak sender] state in
                DispatchQueue.main.async { MainActor.assumeIsolated { if let sender { self?.senderChanged(sender, state) } } }
            }
            self.sender = sender
            otherMacStatus = "Connecting…"
            sender.start()
        }
        applyVolumes()
    }

    private func appsPlayingChanged() {
        hold?.invalidate()
        hold = monitor.isPlaying || engine == nil ? nil : Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hold = nil; self?.update() }
        }
        update()
    }

    private func senderChanged(_ sender: AirPlaySender, _ state: AirPlaySender.State) {
        guard sender === self.sender, let name = running?.other?.name else { return }
        switch state {
        case .connecting: otherMacStatus = "Connecting…"
        case .streaming: otherMacStatus = "Playing"
        case .stopped: otherMacStatus = ""
        case .failed(let reason):
            let refused = reason.contains("pairing refused")
            otherMacStatus = refused
                ? "\(name) refuses. On it: System Settings > General > AirDrop & Handoff > Allow AirPlay for: Anyone on the Same Network"
                : "Cannot reach \(name), retrying"
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: refused ? 20 : 5, repeats: false) { [weak self, weak sender] _ in
                MainActor.assumeIsolated { if let sender, sender === self?.sender { sender.start() } }
            }
        }
    }

    // MARK: Volume

    private func watchMainVolume() {
        let device = outputs.first(where: \.isBuiltIn)?.id
        guard device != mainVolumeControl?.device else { return }
        mainVolumeControl = device.map(SystemVolume.init(device:))
        volumeObservers = mainVolumeControl?.observe { [weak self] in MainActor.assumeIsolated { self?.mainVolumeChanged() } } ?? []
        mainVolumeChanged()
    }

    private func mainVolumeChanged() {
        mainVolume = Double(mainVolumeControl?.position ?? 1)
        applyVolumes()
    }

    /// The main output's device applies the main volume itself; the others get it as gain.
    private func applyVolumes() {
        guard let engine else { return }
        let main = mainVolumeControl
        for (i, output) in engine.outputs.enumerated() {
            let uid = output.device.uid
            let own = Float(volume(uid))
            let ticked = chosenOutputs.contains(uid)
            output.gain.value = ticked ? own * own * (i == 0 ? 1 : main?.gain ?? 1) : 0
        }
        // AirPlay volume follows the slider position: -30 dB (quietest) ... 0 dB, below that silent.
        let position = (main?.isMuted ?? false ? 0 : Double(main?.position ?? 1)) * volume(Self.other)
        sender?.volumeDB = position <= 0 ? -144 : Float(-30 + 30 * position)
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
