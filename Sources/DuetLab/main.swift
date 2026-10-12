import CoreAudio
import CryptoKit
@testable import DuetCore
import Foundation
import Network

// Development and measurement tool for Duet. Not shipped in the app.
setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func device(named name: String) -> OutputDevice {
    guard let d = OutputDevice.all().first(where: { $0.name == name }) else {
        fatalError("no output device named \(name); have: \(OutputDevice.all().map(\.name))")
    }
    return d
}
func inputDevice(named name: String) -> AudioObjectID {
    let ids = OutputDevice.allDeviceIDs()
    guard let id = ids.first(where: { OutputDevice.name(of: $0) == name }) else { fatalError("no device named \(name)") }
    return id
}
let micName = option("mic") ?? "MacBook Pro Microphone"

switch args.first {
case "devices":
    let def = OutputDevice.defaultOutput()
    for d in OutputDevice.all() {
        print("\(d.id)\t\(d.name)\tuid=\(d.uid)\trate=\(d.nominalSampleRate)\tlatency=\(d.outputLatencyFrames)\tbluetooth=\(d.isBluetooth)\(d.id == def?.id ? "\tDEFAULT" : "")")
    }

case "probe":
    // Click directly on a speaker and time the arrivals at the microphone (validates the measuring chain).
    let speaker = device(named: option("speaker") ?? "MacBook Pro Speakers")
    let probe = AcousticProbe()
    let count = Int(option("count") ?? "5")!
    let amplitude = Float(option("amp") ?? "0.2")!
    let t0 = probe.now() + 0.8
    let refs = (0..<count).map { t0 + Double($0) * 0.5 }
    var emitted: [Double] = []
    let rec = try probe.record(device: inputDevice(named: micName), duration: Double(count) * 0.5 + 1.5) {
        DispatchQueue.global().async { emitted = (try? probe.playClicks(device: speaker.id, at: refs, amplitude: amplitude)) ?? [] }
    }
    print("emitted offsets vs schedule (ms):", zip(emitted, refs).map { String(format: "%.2f", ($0 - $1) * 1000) })
    for (i, found) in probe.detect(in: rec, references: refs, minDelay: -0.05, maxDelay: 0.3, peaks: Int(option("peaks") ?? "1")!).enumerated() {
        print("click \(i):", found.map { String(format: "%.2f ms (snr %.0f)", $0.delay * 1000, $0.strength) })
    }

case "clicks":
    // Child process for capture tests: plays clicks at the given host times (seconds) on any output
    // device, virtual ones included, as the device's reported latency places them.
    let speaker = inputDevice(named: option("speaker") ?? "MacBook Pro Speakers")
    let times = option("at")!.split(separator: ",").map { Double($0)! }
    _ = try AcousticProbe().playClicks(device: speaker, at: times, amplitude: Float(option("amp") ?? "0.1")!)

case "capture-test":
    // A child plays clicks on the speaker. Duet taps only that child (muting it), delays the sound by
    // --delay seconds and plays it on the same speaker. The mic proves: the direct click is gone,
    // the delayed click is heard, and it is heard when the engine's timeline says it is.
    let speaker = device(named: option("speaker") ?? "MacBook Pro Speakers")
    let delay = Double(option("delay") ?? "0.3")!
    let probe = AcousticProbe()
    let t0 = probe.now() + 2.0
    let refs = (0..<4).map { t0 + Double($0) * 0.5 }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["clicks", "--speaker", speaker.name, "--amp", option("amp") ?? "0.1",
                       "--at", refs.map { String($0) }.joined(separator: ",")]
    try child.run()
    Thread.sleep(forTimeInterval: 0.6)
    let engine = Engine(input: .captureOnly([child.processIdentifier]), outputs: [speaker], delaySeconds: delay)
    try engine.start()
    let rec = try probe.record(device: inputDevice(named: micName), duration: 2.0 + 1.5 + delay + 0.8)
    child.waitUntilExit()
    engine.stop()

    // Where each click landed in the captured stream, and when the engine says that frame was heard.
    let total = engine.ring.writeIndex
    var captured = [Float](repeating: 0, count: total * 2)
    let readOK = captured.withUnsafeMutableBufferPointer { engine.ring.read(at: 0, frames: total, into: $0.baseAddress!) }
    let left = stride(from: 0, to: captured.count, by: 2).map { captured[$0] }
    print("captured \(total) frames (read \(readOK)), peak \(left.map(abs).max() ?? 0), output latency \(engine.outputLatencyFrames) frames")
    let positions = findClicks(in: left, sampleRate: engine.sampleRate)
    let heard = positions.compactMap { engine.heardTime(ofFrame: $0) }
    print("clicks found in captured stream:", positions.count)
    let direct = probe.detect(in: rec, references: refs, minDelay: 0, maxDelay: 0.08)
    let delayed = probe.detect(in: rec, references: heard, minDelay: -0.02, maxDelay: 0.1)
    for i in 0..<refs.count {
        let d = direct[i].first.map { String(format: "snr %.0f", $0.strength) } ?? "-"
        let e = i < heard.count ? String(format: "%.2f ms", (heard[i] - refs[i] - delay) * 1000) : "-"
        let h = i < delayed.count ? (delayed[i].first.map { String(format: "%.2f ms (snr %.0f)", $0.delay * 1000, $0.strength) } ?? "-") : "-"
        print("click \(i): direct path \(d) | extra capture delay \(e) | mic vs predicted \(h)")
    }

case "loop":
    // The whole stream path on this Mac: a child's clicks are captured (silent here), sent over UDP to
    // 127.0.0.1, received, and played on the speaker at the moment the sender says. The microphone
    // should hear them as late versus prediction as the capture-test's direct playback (about 29 ms).
    let speaker = device(named: option("speaker") ?? "MacBook Pro Speakers")
    let delay = Double(option("delay") ?? "0.15")!
    let seconds = Double(option("seconds") ?? "8")!
    let probe = AcousticProbe()
    let t0 = probe.now() + 3.0
    let refs = (0..<max(1, Int((seconds - 3.5) / 0.5))).map { t0 + Double($0) * 0.5 }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["clicks", "--speaker", speaker.name, "--amp", option("amp") ?? "0.1", "--at", refs.map { String($0) }.joined(separator: ",")]
    try child.run()
    Thread.sleep(forTimeInterval: 0.6)
    let source = Engine(input: .captureOnly([child.processIdentifier]), outputs: [speaker], delaySeconds: delay)
    source.outputs[0].gain.value = 0
    try source.start()
    let k1 = SymmetricKey(size: .bits256), k2 = SymmetricKey(size: .bits256)
    let sender = try StreamSender(engine: source, crypto: DatagramCrypto(send: k1, receive: k2))
    sender.start()
    let receiver = StreamReceiver(crypto: DatagramCrypto(send: k2, receive: k1), name: sender.name)
    receiver.start()
    let sink = Engine(input: .network(receiver), outputs: [speaker], delaySeconds: 0, sourceRate: source.sampleRate)
    try sink.start()
    let stats = Thread {
        while true {
            Thread.sleep(forTimeInterval: 1)
            printStats(receiver.takeStats())
        }
    }
    stats.start()
    let rec = try probe.record(device: inputDevice(named: micName), duration: seconds + delay + 0.5)
    child.waitUntilExit()
    sink.stop(); receiver.stop(); sender.stop(); source.stop()
    let total = source.ring.writeIndex
    let kept = min(total, source.ring.capacity)
    var captured = [Float](repeating: 0, count: kept * 2)
    _ = captured.withUnsafeMutableBufferPointer { source.ring.read(at: total - kept, frames: kept, into: $0.baseAddress!) }
    let left = stride(from: 0, to: captured.count, by: 2).map { captured[$0] }
    let heard = findClicks(in: left, sampleRate: source.sampleRate).compactMap { source.heardTime(ofFrame: $0 + total - kept) }
    for (i, arrivals) in probe.detect(in: rec, references: heard, minDelay: -0.05, maxDelay: 0.2, peaks: 2).enumerated() {
        print("click \(i): mic vs predicted", arrivals.map { String(format: "%.2f ms (snr %.0f)", $0.delay * 1000, $0.strength) })
    }

case "send":
    // Cross-Mac network test, sending side: streams a silent child's capture (nothing is heard here)
    // with the shared --key, for --seconds; prints the stream's name for the receiving side.
    let seconds = Double(option("seconds") ?? "30")!
    let silent = Process()
    silent.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    silent.arguments = ["clicks", "--amp", "0", "--at", String(AcousticProbe().now() + seconds + 2)]
    try silent.run()
    Thread.sleep(forTimeInterval: 0.6)
    let source = Engine(input: .captureOnly([silent.processIdentifier]), outputs: [device(named: "MacBook Pro Speakers")],
                        delaySeconds: Double(option("delay") ?? "0.15")!)
    source.outputs[0].gain.value = 0
    try source.start()
    let (toReceiver, toSender) = labKeys(option("key")!)
    let sender = try StreamSender(engine: source, crypto: DatagramCrypto(send: toReceiver, receive: toSender))
    sender.start()
    print("sending as \(sender.name)")
    Thread.sleep(forTimeInterval: seconds)
    sender.stop(); source.stop(); silent.terminate()

case "mic-check":
    // Records --seconds of the microphone and prints its level: all zeros means no permission.
    let rec = try AcousticProbe().record(device: inputDevice(named: micName), duration: Double(option("seconds") ?? "1")!)
    let rms = (rec.samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, rec.samples.count))).squareRoot()
    print("samples", rec.samples.count, String(format: "rms %.6f peak %.4f", rms, rec.samples.map(abs).max() ?? 0))

case "p2p-serve":
    // Stand-in for the sound stream over the system networking API (which may use the direct
    // Mac-to-Mac Wi-Fi link): sends 1000 bytes every 5 ms, stamped with the send time, to each
    // client that says hello, for --seconds.
    let parameters = NWParameters.udp
    parameters.includePeerToPeer = true
    parameters.serviceClass = .interactiveVoice
    let port = NWEndpoint.Port(rawValue: UInt16(option("port") ?? "47200")!)!
    let listener = try NWListener(using: parameters, on: port)
    listener.service = NWListener.Service(name: "duet-lab-\(port)", type: "_duetlab._udp")
    let queue = DispatchQueue(label: "serve", qos: .userInteractive)
    listener.newConnectionHandler = { connection in
        print("client", connection.endpoint)
        connection.start(queue: queue)
        var seq: UInt64 = 0
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .microseconds(200))
        timer.setEventHandler {
            var packet = [UInt8](repeating: 0, count: 1000)
            withUnsafeBytes(of: seq) { packet.replaceSubrange(0..<8, with: $0) }
            withUnsafeBytes(of: HostClock.now) { packet.replaceSubrange(8..<16, with: $0) }
            connection.send(content: Data(packet), completion: .idempotent)
            seq += 1
        }
        timer.resume()
        connection.stateUpdateHandler = { if case .cancelled = $0 { timer.cancel() } }
    }
    listener.stateUpdateHandler = { print("listener", $0) }
    listener.start(queue: queue)
    Thread.sleep(forTimeInterval: Double(option("seconds") ?? "200")!)

case "p2p-browse":
    // Browses --type over every interface, including the direct Mac-to-Mac link, for --seconds,
    // printing each result's interfaces.
    let parameters = NWParameters()
    parameters.includePeerToPeer = true
    let browser = NWBrowser(for: .bonjour(type: option("type") ?? "_duet._tcp", domain: nil), using: parameters)
    browser.browseResultsChangedHandler = { results, _ in
        for r in results { print(r.endpoint, r.interfaces.map { "\($0.name) \($0.type)" }) }
    }
    browser.start(queue: DispatchQueue(label: "browse"))
    Thread.sleep(forTimeInterval: Double(option("seconds") ?? "60")!)

case "p2p-listen":
    // Receives p2p-serve's packets from --host:--port and prints, every 10 s, their delay variation
    // (arrival minus send time, minus the smallest seen, so the clock offset cancels).
    let parameters = NWParameters.udp
    parameters.includePeerToPeer = true
    parameters.serviceClass = .interactiveVoice
    (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.shouldCalculateReceiveTime = true
    let queue = DispatchQueue(label: "listen", qos: .userInteractive)
    var endpoint: NWEndpoint?
    if let service = option("service") {
        // Find the service over the direct link and require that link for the connection.
        let browser = NWBrowser(for: .bonjour(type: "_duetlab._udp", domain: nil), using: parameters)
        let found = DispatchSemaphore(value: 0)
        browser.browseResultsChangedHandler = { results, _ in
            for r in results where "\(r.endpoint)".contains(service) {
                print("found", r.endpoint, r.interfaces.map(\.name))
                if let direct = r.interfaces.first(where: { $0.name.hasPrefix("awdl") }), endpoint == nil {
                    parameters.requiredInterface = direct
                    endpoint = r.endpoint
                    found.signal()
                }
            }
        }
        browser.start(queue: queue)
        _ = found.wait(timeout: .now() + 10)
    } else {
        endpoint = .hostPort(host: NWEndpoint.Host(option("host")!), port: NWEndpoint.Port(rawValue: UInt16(option("port") ?? "47200")!)!)
    }
    guard let endpoint else { fatalError("not found over the direct link") }
    let connection = NWConnection(to: endpoint, using: parameters)
    let lock = NSLock()
    var delays = [Double](), lastSeq: UInt64?, lost = 0, all = [Double]()
    let dump = option("dump")   // file for every packet: sequence, arrival, send time
    var dumped = [(UInt64, Double, Double)]()
    func receive() {
        connection.receiveMessage { data, context, _, error in
            if let data, data.count >= 16 {
                let seq = data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                let sent = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Double.self) }
                let meta = context?.protocolMetadata(definition: NWProtocolIP.definition) as? NWProtocolIP.Metadata
                let arrival = (meta?.receiveTime).map { Double($0) / 1e9 } ?? Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
                lock.lock()
                if let lastSeq, seq > lastSeq + 1 { lost += Int(seq - lastSeq - 1) }
                lastSeq = max(lastSeq ?? 0, seq)
                delays.append(arrival - sent)
                if dump != nil { dumped.append((seq, arrival, sent)) }
                lock.unlock()
            }
            if error == nil { receive() } else { print("receive error", error!) }
        }
    }
    connection.stateUpdateHandler = { print("connection", $0, connection.currentPath?.localEndpoint.map { "\($0)" } ?? "") }
    connection.start(queue: queue)
    receive()
    for second in 1...Int(option("seconds") ?? "180")! {
        connection.send(content: Data("hello".utf8), completion: .idempotent)
        Thread.sleep(forTimeInterval: 1)
        guard second % 10 == 0 else { continue }
        lock.lock(); all += delays; let window = delays; delays.removeAll(); let l = lost; lock.unlock()
        guard let base = all.min(), !window.isEmpty else { print("no packets"); continue }
        let v = window.map { ($0 - base) * 1000 }.sorted()
        func q(_ p: Double) -> Double { v[min(v.count - 1, Int(p * Double(v.count)))] }
        print(String(format: "%3ds packets %5d lost %3d | variation median %5.1f p99 %6.1f max %6.1f ms | >20 %3d >50 %3d >100 %3d",
                     second, v.count, l, q(0.5), q(0.99), v.last!, v.filter { $0 > 20 }.count, v.filter { $0 > 50 }.count, v.filter { $0 > 100 }.count))
    }

    if let dump {
        lock.lock()
        try dumped.map { "\($0.0) \($0.1) \($0.2)" }.joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
        lock.unlock()
    }

case "audio-processes":
    // Lists the processes that use audio now: pid, input/output running, bundle ID.
    for id in (try? CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self)) ?? [] {
        let pid = (try? CA.scalar(id, kAudioProcessPropertyPID, as: pid_t.self)) ?? -1
        let output = (try? CA.scalar(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0
        let input = (try? CA.scalar(id, kAudioProcessPropertyIsRunningInput, as: UInt32.self)) ?? 0
        let bundle = (try? CA.string(id, kAudioProcessPropertyBundleID)) ?? "?"
        if output != 0 || input != 0 { print(pid, "output", output, "input", input, bundle) }
    }

case "link":
    // Two links in this process: they find each other on the network, pair (codes auto-confirmed and
    // compared), open a session and exchange one message each way. Pairings stay in memory.
    MainActor.assumeIsolated {
        let a = Link(me: Link.Peer(id: "lab-a-" + UUID().uuidString, name: "Duet Lab A"), pairing: nil)
        let b = Link(me: Link.Peer(id: "lab-b-" + UUID().uuidString, name: "Duet Lab B"), pairing: nil)
        var codes = [String]()
        for (link, name) in [(a, "A"), (b, "B")] {
            link.confirm = { peer, code, reply in print("\(name): pair with \(peer.name)? code \(code)"); codes.append(code); reply(true) }
            link.onPaired = { print("\(name): paired with \($0.peer.name)") }
            link.onMessage = { print("\(name) received", $0) }
            link.start()
        }
        func spin(_ seconds: Double, until done: () -> Bool) -> Bool {
            let end = Date() + seconds
            while Date() < end, !done() { RunLoop.main.run(until: Date() + 0.05) }
            return done()
        }
        let started = Date()
        func t() -> String { String(format: "%.2f s", Date().timeIntervalSince(started)) }
        print("A sees B:", spin(10) { a.nearby.contains { $0.id == b.me.id } }, t())
        a.pair(with: a.nearby.first { $0.id == b.me.id }!)
        print("paired:", spin(10) { a.pairing != nil && b.pairing != nil }, codes, "same code:", Set(codes).count == 1, t())
        print("sessions:", spin(10) { a.session != nil && b.session != nil }, t())
        a.send(["t": "hi", "from": "A"])
        b.send(["t": "hi", "from": "B"])
        _ = spin(1) { false }
        // A stranger with the right ID but no secret must not get a session.
        let fake = Link(me: Link.Peer(id: a.me.id, name: "Fake A"), pairing: Link.Pairing(peer: b.me, key: SymmetricKey(size: .bits256)))
        fake.onChange = { if fake.session != nil { print("FAKE GOT A SESSION") } }
        fake.start()
        _ = spin(6) { false }
        print("fake note:", fake.note ?? "-", "| B session still with:", b.session?.peer.name ?? "none")
    }

case "receive":
    // Cross-Mac network test, receiving side: plays the stream named --name at --gain (default 0,
    // silent) and prints the link statistics every second.
    let (toReceiver, toSender) = labKeys(option("key")!)
    let receiver = StreamReceiver(crypto: DatagramCrypto(send: toSender, receive: toReceiver), name: option("name")!)
    receiver.start()
    let sink = Engine(input: .network(receiver), outputs: [device(named: "MacBook Pro Speakers")], delaySeconds: 0, sourceRate: 48_000)
    sink.outputs[0].gain.value = Float(option("gain") ?? "0")!
    try sink.start()
    for _ in 0..<Int(option("seconds") ?? "30")! {
        Thread.sleep(forTimeInterval: 1)
        printStats(receiver.takeStats())
    }
    sink.stop(); receiver.stop()

case "calibrate":
    // Runs the engine on several outputs and calibrates them against the main one with the microphone,
    // --passes times: after the first pass every output should read about 0 ms. The engine captures
    // only a silent child (an empty capture never starts, and capturing this tool would loop).
    let names = (option("speakers") ?? "MacBook Pro Speakers,LG HDR 4K").split(separator: ",").map(String.init)
    let passes = Int(option("passes") ?? "2")!
    let hold = Double(option("hold") ?? "0")!   // seconds of playback between passes (drift check)
    let silent = Process()
    silent.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    silent.arguments = ["clicks", "--amp", "0", "--at", String(AcousticProbe().now() + 2 + Double(passes * names.count) * 2.5 + hold * Double(passes))]
    try silent.run()
    Thread.sleep(forTimeInterval: 0.6)
    let engine = Engine(input: .captureOnly([silent.processIdentifier]), outputs: names.map(device(named:)), delaySeconds: Double(option("delay") ?? "0.3")!)
    try engine.start()
    Thread.sleep(forTimeInterval: 0.5)
    print("aggregate latency \(engine.outputLatencyFrames) frames; buffers per output:", engine.outputs.map { CA.bufferCount($0.device.id, kAudioObjectPropertyScopeOutput) })
    for pass in 1...passes {
        let results = try Calibration.run(engine, microphone: inputDevice(named: micName))
        let main = results[0].delay ?? .nan
        for r in results {
            print("pass \(pass): \(r.output): mic vs predicted \(r.delay.map { String(format: "%.2f ms", $0 * 1000) } ?? "not heard"),",
                  "vs main \(r.delay.map { String(format: "%+.2f ms", ($0 - main) * 1000) } ?? "-"), snr \(Int(r.strength))")
        }
        print("lags now:", engine.outputs.map { String(format: "%.2f ms", $0.lag.value * 1000) })
        if pass < passes { Thread.sleep(forTimeInterval: hold) }
    }
    engine.stop()
    silent.terminate()

case "follow":
    // Silent check that every output but the main one gets the stream in time: runs the engine with all
    // gains at 0 and the delay the outputs need minus --short seconds, then prints the frames each output
    // played as silence because the stream was not there yet (0 expected with --short 0).
    let names = (option("speakers") ?? "MacBook Pro Speakers,LG HDR 4K").split(separator: ",").map(String.init)
    let devices = names.map(device(named:))
    let lag = Double(option("lag") ?? "0")!
    let seconds = Double(option("seconds") ?? "10")!
    let lead = devices.map { Engine.lead(of: $0, lag: lag, main: devices[0]) }.max() ?? 0
    let silent = Process()
    silent.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    silent.arguments = ["clicks", "--amp", "0", "--at", String(AcousticProbe().now() + seconds + 2)]
    try silent.run()
    Thread.sleep(forTimeInterval: 0.6)
    let engine = Engine(input: .captureOnly([silent.processIdentifier]), outputs: devices,
                        delaySeconds: max(0, lead - Double(option("short") ?? "0")!))
    engine.mainGain.value = 0
    for output in engine.outputs {
        output.gain.value = 0
        output.lag.value = Float(lag)
    }
    try engine.start()
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()
    silent.terminate()
    print(String(format: "delay %.1f ms (lead %.1f ms)", Double(engine.delayFrames) / engine.sampleRate * 1000, lead * 1000))
    for output in engine.outputs {
        print("\(output.device.name): rate \(output.device.nominalSampleRate), buffer \(output.device.bufferFrames), latency \(String(format: "%.1f", output.device.outputLatency * 1000)) ms, silent frames \(output.missed.load(ordering: .relaxed))")
    }

case "device-path":
    // Silent: a child plays clicks on an output (--device) as an app would, the engine captures them (every
    // output at gain 0), and the engine's timeline says when each would be heard. Prints the latency
    // Ensemble's sound device must report for that, and its capture part (Duet.capturePath): the rest is
    // the delay and the main output's latency. The capture part does not depend on the device clicked on
    // (85.1 ms on the speakers, 86.1 ms on a virtual device, 2026-10-12).
    let name = option("device") ?? "MacBook Pro Speakers"
    let target = inputDevice(named: name)
    let rate = (try? CA.scalar(target, kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 48_000
    let reported = Double(CA.outputLatencyFrames(target)) / rate
    let delay = Double(option("delay") ?? "0.15")!
    let t0 = AcousticProbe().now() + 2.0
    let refs = (0..<6).map { t0 + reported + Double($0) * 0.4 }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["clicks", "--speaker", name, "--amp", "0.1", "--at", refs.map { String($0) }.joined(separator: ",")]
    try child.run()
    Thread.sleep(forTimeInterval: 0.6)
    let engine = Engine(input: .captureOnly([child.processIdentifier]), outputs: [device(named: "MacBook Pro Speakers")], delaySeconds: delay)
    engine.outputs[0].gain.value = 0
    try engine.start()
    child.waitUntilExit()
    Thread.sleep(forTimeInterval: delay + 0.2)
    let total = engine.ring.writeIndex
    var captured = [Float](repeating: 0, count: total * 2)
    _ = captured.withUnsafeMutableBufferPointer { engine.ring.read(at: 0, frames: total, into: $0.baseAddress!) }
    let positions = findClicks(in: stride(from: 0, to: captured.count, by: 2).map { captured[$0] }, sampleRate: engine.sampleRate)
    let heard = positions.compactMap { engine.heardTime(ofFrame: $0) }
    let main = Double(engine.outputLatencyFrames) / engine.sampleRate
    engine.stop()
    print(String(format: "device reports %.1f ms; delay %.1f ms; main output %.1f ms; clicks %d", reported * 1000, delay * 1000, main * 1000, heard.count))
    for (h, r) in zip(heard, refs) {
        let needed = h - (r - reported)
        print(String(format: "needed latency %.2f ms, capture path %.2f ms", needed * 1000, (needed - delay - main) * 1000))
    }

case "hold":
    // Runs the product engine (every app but this tool) on --speakers for --seconds.
    let names = (option("speakers") ?? "MacBook Pro Speakers,LG HDR 4K").split(separator: ",").map(String.init)
    let engine = Engine(input: .captureAllExcept([getpid()]), outputs: names.map(device(named:)), delaySeconds: Double(option("delay") ?? "0")!)
    try engine.start()
    print("holding; latency", engine.outputLatencyFrames)
    Thread.sleep(forTimeInterval: Double(option("seconds") ?? "10")!)
    engine.stop()

case "monitor":
    // Prints when apps start and stop playing sound, for --seconds.
    let monitor = PlaybackMonitor(excluding: [getpid()])
    let t0 = Date()
    monitor.onChange = { print(String(format: "%.2f s: playing %@", Date().timeIntervalSince(t0), $0 ? "yes" : "no")) }
    monitor.start()
    print("start: playing", monitor.isPlaying)
    RunLoop.main.run(until: Date() + Double(option("seconds") ?? "10")!)

case "media":
    // Sends one media command (play, pause, playPause, next, previous) to the now-playing app.
    print(MediaCommand(rawValue: args[1])!.perform() ? "sent" : "not sent")
    Thread.sleep(forTimeInterval: 0.8)   // the system checks the sender after the call returns

case "nowplaying":
    // A stand-in music app: becomes the now-playing app and logs the commands it receives.
    NowPlayingStandIn.run(seconds: Double(option("seconds") ?? "12")!)

default:
    print("usage: duet-lab devices | probe | capture-test | loop | calibrate | hold | monitor | media CMD | nowplaying")
}

/// Frame indices of click onsets in a captured stream (strongest matched-filter peaks, 0.2 s apart).
func findClicks(in samples: [Float], sampleRate: Double) -> [Int] {
    let click = AcousticProbe.clickWaveform(sampleRate: sampleRate)
    guard samples.count > click.count else { return [] }
    var y = [Float](repeating: 0, count: samples.count - click.count)
    samples.withUnsafeBufferPointer { s in
        for i in y.indices {
            var dot: Float = 0
            for k in 0..<click.count { dot += s[i + k] * click[k] }
            y[i] = abs(dot)
        }
    }
    guard let top = y.max(), top > 0 else { return [] }
    var found = [Int]()
    for i in y.indices.sorted(by: { y[$0] > y[$1] }) {
        if y[i] < top * 0.3 { break }
        if found.contains(where: { abs($0 - i) < Int(0.2 * sampleRate) }) { continue }
        found.append(i)
    }
    return found.sorted()
}

func labKeys(_ hexKey: String) -> (SymmetricKey, SymmetricKey) {
    let key = SymmetricKey(data: stride(from: 0, to: hexKey.count, by: 2).map {
        UInt8(hexKey[hexKey.index(hexKey.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
    })
    return (Seal.derive(key, salt: [], "to receiver"), Seal.derive(key, salt: [], "to sender"))
}

func printStats(_ s: StreamReceiver.Stats) {
    print(String(format: "routes %d packets %d resent %d concealed %d jumps %d | margin min %.1f ms | rtt %.2f ms offset %.3f ms drift %.1f ppm | error %.3f ms",
                 s.routes, s.packets, s.resent, s.concealed, s.jumps, s.minMargin * 1000, s.roundTrip * 1000, s.offset.truncatingRemainder(dividingBy: 1) * 1000, s.drift * 1e6, s.error * 1000))
}
