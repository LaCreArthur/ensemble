import CryptoKit
import Foundation

/// Turns captured frames into encrypted 44.1 kHz RTP packets and sync packets, and keeps a backlog
/// for retransmission requests. `pump` runs on one thread, `serveRetransmits` on another.
final class AudioStream: @unchecked Sendable {
    let firstSequence = UInt16.random(in: 0...UInt16.max)
    let firstTimestamp = UInt32.random(in: 0...0x3fff_ffff)

    private let capture: CaptureEngine
    private let clock: NTPClock
    private let key: SymmetricKey
    private let ssrc: UInt32
    private let audioSocket: UDPSocket, controlSocket: UDPSocket
    private let dataAddress: sockaddr_in, controlAddress: sockaddr_in
    private let resampler: Resampler

    private var x0 = -1                 // capture frame under stream frame 0
    private var next = 0                // next stream frame to send
    private var nonceCounter: UInt64 = 0
    private var lastSync = 0.0
    private var sentSync = false
    private var input = [Float]()
    private var pcm = [UInt8](repeating: 0, count: AirPlaySender.framesPerPacket * 4)

    private let backlogLock = NSLock()
    private var backlog = [UInt16: [UInt8]]()

    init(capture: CaptureEngine, clock: NTPClock, key: [UInt8], ssrc: UInt32, audioSocket: UDPSocket,
         controlSocket: UDPSocket, data: sockaddr_in, control: sockaddr_in) {
        self.capture = capture
        self.clock = clock
        self.key = SymmetricKey(data: key)
        self.ssrc = ssrc
        self.audioSocket = audioSocket
        self.controlSocket = controlSocket
        self.dataAddress = data
        self.controlAddress = control
        resampler = Resampler(inputRate: Int(capture.sampleRate), outputRate: AirPlaySender.streamRate)
    }

    /// Sends every packet whose input has been captured, and a sync packet once per second.
    func pump() {
        let ring = capture.ring
        if x0 < 0 { x0 = ring.writeIndex }
        let now = clock.hostSeconds(mach_absolute_time())
        if !sentSync || now - lastSync >= 1 { sendSync(now: now) }
        let count = AirPlaySender.framesPerPacket
        while true {
            let span = resampler.inputSpan(outputStart: next, count: count)
            if x0 + span.upperBound >= ring.writeIndex { return }
            let needed = span.count
            if input.count < needed * 2 { input = [Float](repeating: 0, count: needed * 2) }
            let ok = input.withUnsafeMutableBufferPointer { ring.read(at: x0 + span.lowerBound, frames: needed, into: $0.baseAddress!) }
            if !ok {
                // Fell more than the ring behind (the Mac was asleep or stalled): restart on fresh frames.
                x0 = ring.writeIndex - resampler.inputSpan(outputStart: next, count: 1).lowerBound
                continue
            }
            input.withUnsafeBufferPointer { resampler.render(input: $0.baseAddress!, outputStart: next, count: count, into: &pcm) }
            send(timestamp: firstTimestamp &+ UInt32(truncatingIfNeeded: next))
            next += count
        }
    }

    private func send(timestamp: UInt32) {
        let sequence = firstSequence &+ UInt16(truncatingIfNeeded: next / AirPlaySender.framesPerPacket)
        let header: [UInt8] = [0x80, next == 0 ? 0xE0 : 0x60] + sequence.bigEndianBytes + timestamp.bigEndianBytes + ssrc.bigEndianBytes
        let nonce = HAPCrypto.nonce(nonceCounter)
        nonceCounter += 1
        let packet = header + HAPCrypto.seal(pcm, key: key, nonce: nonce, aad: Array(header[4..<12])) + Array(nonce[4...])
        audioSocket.send(packet, to: dataAddress)
        backlogLock.lock()
        backlog[sequence] = packet
        backlog[sequence &- 1024] = nil
        backlogLock.unlock()
    }

    /// "RTP frame W plays at time T": W is the stream frame heard on this Mac right now.
    private func sendSync(now: Double) {
        guard x0 >= 0, let (anchorFrame, anchorTicks) = capture.anchor.load() else { return }
        let rate = capture.sampleRate
        let ratio = rate / Double(AirPlaySender.streamRate)
        let anchorTime = clock.hostSeconds(anchorTicks)
        let heardFrame = Double(anchorFrame) + (now - anchorTime) * rate
        let j = Int(((heardFrame - Double(x0)) / ratio).rounded(.down))
        let heardAt = anchorTime + (Double(x0) + Double(j) * ratio - Double(anchorFrame)) / rate
        var packet: [UInt8] = [sentSync ? 0x80 : 0x90, 0xD4, 0x00, 0x07]
        packet += (firstTimestamp &+ UInt32(truncatingIfNeeded: j)).bigEndianBytes
        packet += clock.ntp(heardAt)
        packet += (firstTimestamp &+ UInt32(truncatingIfNeeded: next)).bigEndianBytes
        controlSocket.send(packet, to: controlAddress)
        sentSync = true
        lastSync = now
    }

    /// Answers the receiver's requests for lost packets (waits up to 200 ms for one).
    func serveRetransmits() {
        guard let (request, from) = controlSocket.receive(), request.count >= 8, request[1] & 0x7f == 0x55 else { return }
        let first = UInt16(request[4]) << 8 | UInt16(request[5])
        let count = UInt16(request[6]) << 8 | UInt16(request[7])
        for i in 0..<count {
            backlogLock.lock()
            let packet = backlog[first &+ i]
            backlogLock.unlock()
            if let packet { controlSocket.send([0x80, 0xD6] + packet[2..<4] + packet, to: from) }
        }
    }
}

/// Windowed-sinc rational resampler (for example 48 kHz -> 44.1 kHz = 147/160). Output frame j sits
/// exactly at input position j * inputRate / outputRate, so timing maps without any offset.
final class Resampler {
    let up: Int, down: Int
    private let half = 16  // taps on each side of the output position
    private let coefficients: [[Float]]

    init(inputRate: Int, outputRate: Int) {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(inputRate, outputRate)
        let up = outputRate / g, half = 16
        self.up = up
        down = inputRate / g
        let taps = 2 * half
        let cutoff = min(1.0, Double(outputRate) / Double(inputRate)) * 0.45   // cycles per input sample
        coefficients = (0..<up).map { phase in
            let raw = (0..<taps).map { k -> Double in
                let t = Double(k - half + 1) - Double(phase) / Double(up)
                let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
                let x = t / Double(half)
                let window = abs(x) >= 1 ? 0 : 0.42 + 0.5 * cos(.pi * x) + 0.08 * cos(2 * .pi * x)
                return sinc * window
            }
            let sum = raw.reduce(0, +)
            return raw.map { Float($0 / sum) }
        }
    }

    /// Input frames (relative to the stream start) needed for output frames [start, start + count).
    func inputSpan(outputStart start: Int, count: Int) -> Range<Int> {
        if up == down { return start..<(start + count) }
        return (start * down / up - half + 1)..<((start + count - 1) * down / up + half + 1)
    }

    /// Renders `count` output frames as big-endian 16-bit stereo. `input` starts at inputSpan(...).lowerBound.
    func render(input: UnsafePointer<Float>, outputStart start: Int, count: Int, into out: inout [UInt8]) {
        let base = inputSpan(outputStart: start, count: count).lowerBound
        for i in 0..<count {
            var l: Float = 0, r: Float = 0
            if up == down {
                l = input[i * 2]; r = input[i * 2 + 1]
            } else {
                let position = (start + i) * down
                let n = position / up
                let c = coefficients[position % up]
                let first = (n - half + 1 - base) * 2
                for k in 0..<c.count {
                    l += input[first + k * 2] * c[k]
                    r += input[first + k * 2 + 1] * c[k]
                }
            }
            let sl = Int16(max(-32768, min(32767, (l * 32767).rounded())))
            let sr = Int16(max(-32768, min(32767, (r * 32767).rounded())))
            out[i * 4] = UInt8(truncatingIfNeeded: sl >> 8); out[i * 4 + 1] = UInt8(truncatingIfNeeded: sl)
            out[i * 4 + 2] = UInt8(truncatingIfNeeded: sr >> 8); out[i * 4 + 3] = UInt8(truncatingIfNeeded: sr)
        }
    }
}
