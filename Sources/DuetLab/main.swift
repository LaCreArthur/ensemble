import CoreAudio
import DuetCore
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
    for (i, found) in probe.detect(in: rec, references: refs, minDelay: -0.05, maxDelay: 0.3).enumerated() {
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
    let engine = CaptureEngine(source: .only([child.processIdentifier]), output: speaker, delaySeconds: delay)
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
