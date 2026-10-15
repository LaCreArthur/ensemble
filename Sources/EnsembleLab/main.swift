import CoreAudio
import CryptoKit
@testable import EnsembleCore
import Foundation

// Development and measurement tool for Ensemble. Not shipped in the app.
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
/// Makes Ensemble's sound device exist for this tool (Ensemble must not run: it removes the device when it does not share).
func addEnsembleDevice() {
    EnsembleDevice.setLatency(0)
    Thread.sleep(forTimeInterval: 0.5)
}

switch args.first {
case "devices":
    let def = OutputDevice.defaultOutput()
    for d in OutputDevice.all() {
        print("\(d.id)\t\(d.name)\tuid=\(d.uid)\trate=\(d.nominalSampleRate)\tlatency=\(d.outputLatencyFrames)\tbluetooth=\(d.isBluetooth)\(d.id == def?.id ? "\tDEFAULT" : "")")
    }

case "clicks":
    // Child for device-path: plays clicks at the given host times (seconds) on any output device,
    // virtual ones included, as the device's reported latency places them; prints the times of the whole
    // clicks it played (a click due before its output started is not played).
    let speaker = inputDevice(named: option("speaker") ?? "MacBook Pro Speakers")
    let times = option("at")!.split(separator: ",").map { Double($0)! }
    if let frames = option("buffer").flatMap(UInt32.init) { try? CA.setScalar(speaker, kAudioDevicePropertyBufferFrameSize, frames) }
    let played = try AcousticProbe().playClicks(device: speaker, at: times, amplitude: Float(option("amp") ?? "0.1")!)
    print(played.filter { $0 > 0 }.map { String($0) }.joined(separator: ","))

case "audio-processes":
    // Lists the processes that use audio now: pid, input/output running, bundle ID.
    for id in (try? CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self)) ?? [] {
        let pid = (try? CA.scalar(id, kAudioProcessPropertyPID, as: pid_t.self)) ?? -1
        let output = (try? CA.scalar(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0
        let input = (try? CA.scalar(id, kAudioProcessPropertyIsRunningInput, as: UInt32.self)) ?? 0
        let bundle = (try? CA.string(id, kAudioProcessPropertyBundleID)) ?? "?"
        if output != 0 || input != 0 { print(pid, "output", output, "input", input, bundle) }
    }

case "calibrate":
    // Runs the engine on several outputs and calibrates them against the main one with the microphone,
    // --passes times: after the first pass every output should read about 0 ms. The engine captures
    // Ensemble's sound device, where nothing plays (quit Ensemble first: it owns the device).
    let names = (option("speakers") ?? "MacBook Pro Speakers,LG HDR 4K").split(separator: ",").map(String.init)
    let passes = Int(option("passes") ?? "2")!
    let hold = Double(option("hold") ?? "0")!   // seconds of playback between passes (drift check)
    addEnsembleDevice()
    let engine = Engine(input: .loopback, outputs: names.map(device(named:)), delaySeconds: Double(option("delay") ?? "0.3")!)
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

case "follow":
    // Silent check that every output but the main one gets the stream in time: runs the engine with all
    // gains at 0 and the delay the outputs need minus --short seconds, then prints the frames each output
    // played as silence because the stream was not there yet (0 expected with --short 0). Quit Ensemble first.
    let names = (option("speakers") ?? "MacBook Pro Speakers,LG HDR 4K").split(separator: ",").map(String.init)
    let devices = names.map(device(named:))
    let lag = Double(option("lag") ?? "0")!
    let seconds = Double(option("seconds") ?? "10")!
    let lead = devices.map { Engine.lead(of: $0, lag: lag, main: devices[0]) }.max() ?? 0
    addEnsembleDevice()
    let engine = Engine(input: .loopback, outputs: devices,
                        delaySeconds: max(0, lead - Double(option("short") ?? "0")!))
    engine.mainGain.value = 0
    for output in engine.outputs {
        output.gain.value = 0
        output.lag.value = Float(lag)
    }
    try engine.start()
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()
    print(String(format: "delay %.1f ms (lead %.1f ms)", Double(engine.delayFrames) / engine.sampleRate * 1000, lead * 1000))
    for output in engine.outputs {
        print("\(output.device.name): rate \(output.device.nominalSampleRate), buffer \(output.device.bufferFrames), latency \(String(format: "%.1f", output.device.outputLatency * 1000)) ms, silent frames \(output.missed.load(ordering: .relaxed))")
    }

case "device-path":
    // Silent: the engine runs (every output at gain 0), then a child starts and plays clicks on Ensemble's
    // sound device as an app would (--buffer frames per cycle; the first --lead seconds after it starts,
    // so a small lead checks that a new app's first sound is kept). The engine's timeline says when each
    // click would be heard. Prints the latency the device must report for that, and its capture part
    // (Engine.capturePath): the rest is the delay and the main output's latency. Quit Ensemble first.
    let name = "Ensemble"
    addEnsembleDevice()
    let target = inputDevice(named: name)
    let rate = (try? CA.scalar(target, kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 48_000
    let reported = Double(CA.outputLatencyFrames(target)) / rate
    let delay = Double(option("delay") ?? "0.15")!
    let engine = Engine(input: .loopback, outputs: [device(named: "MacBook Pro Speakers")], delaySeconds: delay)
    engine.outputs[0].gain.value = 0
    try engine.start()
    Thread.sleep(forTimeInterval: 0.5)
    let t0 = AcousticProbe().now() + Double(option("lead") ?? "2")!
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["clicks", "--speaker", name, "--amp", "0.1", "--buffer", option("buffer") ?? "512",
                       "--at", (0..<6).map { String(t0 + reported + Double($0) * 0.4) }.joined(separator: ",")]
    let pipe = Pipe()
    child.standardOutput = pipe
    try child.run()
    child.waitUntilExit()
    let refs = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(whereSeparator: { $0 == "," || $0 == "\n" }).compactMap { Double($0) }
    print(String(format: "first click played %.0f ms after the child was started", ((refs.first ?? .nan) - reported - (t0 - Double(option("lead") ?? "2")!)) * 1000))
    Thread.sleep(forTimeInterval: delay + 0.2)
    let total = engine.ring.writeIndex
    var captured = [Float](repeating: 0, count: total * 2)
    _ = captured.withUnsafeMutableBufferPointer { engine.ring.read(at: 0, frames: total, into: $0.baseAddress!) }
    let positions = findClicks(in: stride(from: 0, to: captured.count, by: 2).map { captured[$0] }, sampleRate: engine.sampleRate)
    let heard = positions.compactMap { engine.heardTime(ofFrame: $0) }
    let main = Double(engine.outputLatencyFrames) / engine.sampleRate
    engine.stop()
    print(String(format: "device reports %.1f ms; delay %.1f ms; main output %.1f ms; clicks played %d, found %d", reported * 1000, delay * 1000, main * 1000, refs.count, heard.count))
    for (h, r) in zip(heard, refs) {
        let needed = h - (r - reported)
        print(String(format: "needed latency %.2f ms, capture path %.2f ms", needed * 1000, (needed - delay - main) * 1000))
    }

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
    let t0 = Date()
    MediaCommand(rawValue: args[1])!.perform { print(String(format: "delivered after %.3f s", Date().timeIntervalSince(t0))); exit(0) }
    RunLoop.main.run(until: Date() + 10)
    print("no delivery in 10 s")

case "nowplaying":
    // A stand-in music app: becomes the now-playing app and logs the commands it receives.
    NowPlayingStandIn.run(seconds: Double(option("seconds") ?? "12")!, resumeAfter: option("resume-after").flatMap(Double.init))

default:
    print("usage: ensemble-lab devices | audio-processes | calibrate | follow | device-path | monitor | media CMD | nowplaying")
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
