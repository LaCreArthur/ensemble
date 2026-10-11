import CoreAudio
import BigInt
@testable import DuetCore
import Foundation

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
        print("\(d.id)\t\(d.name)\tuid=\(d.uid)\trate=\(d.nominalSampleRate)\tlatency=\(d.outputLatencyFrames)\tpersonal=\(d.isPersonal)\(d.id == def?.id ? "\tDEFAULT" : "")")
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
    // Child process for capture tests: plays clicks at the given host times (seconds) on a speaker.
    let speaker = device(named: option("speaker") ?? "MacBook Pro Speakers")
    let times = option("at")!.split(separator: ",").map { Double($0)! }
    _ = try AcousticProbe().playClicks(device: speaker.id, at: times, amplitude: Float(option("amp") ?? "0.1")!)

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
    let engine = CaptureEngine(source: .only([child.processIdentifier]), outputs: [speaker], delaySeconds: delay)
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
    guard let (anchorFrame, anchorHost) = engine.anchor.load() else { fatalError("no anchor") }
    let positions = findClicks(in: left, sampleRate: engine.sampleRate)
    let heard = positions.map { probe.seconds(anchorHost) + Double($0 - Int(anchorFrame)) / engine.sampleRate }
    print("clicks found in captured stream:", positions.count)
    let direct = probe.detect(in: rec, references: refs, minDelay: 0, maxDelay: 0.08)
    let delayed = probe.detect(in: rec, references: heard, minDelay: -0.02, maxDelay: 0.1)
    for i in 0..<refs.count {
        let d = direct[i].first.map { String(format: "snr %.0f", $0.strength) } ?? "-"
        let e = i < heard.count ? String(format: "%.2f ms", (heard[i] - refs[i] - delay) * 1000) : "-"
        let h = i < delayed.count ? (delayed[i].first.map { String(format: "%.2f ms (snr %.0f)", $0.delay * 1000, $0.strength) } ?? "-") : "-"
        print("click \(i): direct path \(d) | extra capture delay \(e) | mic vs predicted \(h)")
    }

case "stream":
    // Streams a child's clicks to an AirPlay receiver while playing them here, and records the mic.
    let speaker = device(named: "MacBook Pro Speakers")
    let delay = Double(option("delay") ?? "0.3")!
    let seconds = Double(option("seconds") ?? "6")!
    let probe = AcousticProbe()
    let t0 = probe.now() + 3.0
    let count = Int((seconds - 3.5) / 0.5)
    let refs = (0..<max(1, count)).map { t0 + Double($0) * 0.5 }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["clicks", "--amp", option("amp") ?? "0.05", "--at", refs.map { String($0) }.joined(separator: ",")]
    try child.run()
    Thread.sleep(forTimeInterval: 0.6)
    let engine = CaptureEngine(source: .only([child.processIdentifier]), outputs: [speaker], delaySeconds: delay)
    try engine.start()
    let host = option("host") ?? "192.168.1.24"
    let sender = AirPlaySender(endpoint: .hostPort(host: .init(host), port: 7000), capture: engine)
    sender.volumeDB = Float(option("volume") ?? "-20")!
    sender.onLog = { print($0) }
    sender.onState = { print("STATE", $0) }
    sender.start()
    let rec = try probe.record(device: inputDevice(named: micName), duration: seconds + delay + 0.5)
    sender.stop()
    child.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.5)
    engine.stop()
    guard let (anchorFrame, anchorHost) = engine.anchor.load() else { fatalError("no anchor") }
    let total = engine.ring.writeIndex
    let kept = min(total, engine.ring.capacity)
    let firstFrame = total - kept
    var captured = [Float](repeating: 0, count: kept * 2)
    _ = captured.withUnsafeMutableBufferPointer { engine.ring.read(at: firstFrame, frames: kept, into: $0.baseAddress!) }
    let left = stride(from: 0, to: captured.count, by: 2).map { captured[$0] }
    let heard = findClicks(in: left, sampleRate: engine.sampleRate).map {
        probe.seconds(anchorHost) + Double($0 + firstFrame - Int(anchorFrame)) / engine.sampleRate
    }
    for (i, arrivals) in probe.detect(in: rec, references: heard, minDelay: -0.1, maxDelay: 0.6, peaks: 3).enumerated() {
        print("click \(i):", arrivals.map { String(format: "%.1f ms (snr %.0f)", $0.delay * 1000, $0.strength) })
    }

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
    let engine = CaptureEngine(source: .only([silent.processIdentifier]), outputs: names.map(device(named:)), delaySeconds: Double(option("delay") ?? "0.3")!)
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

case "hold":
    // Runs the product engine (every app but this tool) on --speakers for --seconds.
    let names = (option("speakers") ?? "MacBook Pro Speakers,LG HDR 4K").split(separator: ",").map(String.init)
    let engine = CaptureEngine(source: .allExcept([getpid()]), outputs: names.map(device(named:)), delaySeconds: Double(option("delay") ?? "0")!)
    try engine.start()
    print("holding")
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

case "receivers":
    // Lists the other Macs that accept AirPlay, as the app's picker shows them.
    let browser = ReceiverBrowser()
    browser.onChange = { list in for r in list { print("\(r.name)\t\(r.model)\tid=\(r.id)") }; print("--") }
    browser.start()
    RunLoop.main.run(until: Date().addingTimeInterval(3))

case "pair-probe":
    // Exit 0 when the receiver accepts the first step of transient pairing (its access setting allows us).
    let stream = TCPStream(host: option("host") ?? "192.168.1.24", port: 7000)
    try stream.open()
    let rtsp = RTSPClient(stream: stream)
    let reply = try rtsp.request("POST", "/pair-setup", protocol: "HTTP/1.1",
                                 headers: [("User-Agent", "AirPlay/320.20"), ("X-Apple-HKP", "4")],
                                 body: [UInt8](TLV8.encode([(TLV8.method, [0]), (TLV8.seqNo, [1]), (TLV8.flags, [0x10])])),
                                 contentType: "application/octet-stream")
    print(reply.firstLine)
    exit(reply.status == 200 ? 0 : 1)

case "media":
    // Sends one media command (play, pause, playPause, next, previous) to the now-playing app.
    print(MediaCommand(rawValue: args[1])!.perform() ? "sent" : "not sent")
    Thread.sleep(forTimeInterval: 0.8)   // the system checks the sender after the call returns

case "nowplaying":
    // A stand-in music app: becomes the now-playing app and logs the commands it receives.
    NowPlayingStandIn.run(seconds: Double(option("seconds") ?? "12")!)

case "srp":
    // Prints A, M1, K for a given salt and server public key (checked against a reference server).
    let srp = SRPClient()
    let r = srp.respond(salt: hex(option("salt")!), serverPublic: BigUInt(option("B")!, radix: 16)!, password: option("pin") ?? "3939")!
    print(hexString(r.publicKey)); print(hexString(r.proof)); print(hexString(r.sessionKey)); print(hexString(r.expectedServerProof))

default:
    print("usage: duet-lab devices | probe [--speaker NAME] [--count N] [--amp A] [--mic NAME] | capture-test [--delay S]")
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

func hex(_ s: String) -> [UInt8] {
    var bytes = [UInt8](); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); bytes.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return bytes
}
func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
