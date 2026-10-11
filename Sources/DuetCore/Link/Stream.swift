import CryptoKit
import Foundation
import Synchronization

/// The sound stream between the two Macs, over UDP. The sending Mac (its apps' sound) sends 5 ms
/// packets of 16-bit stereo, each saying which capture frame it starts with and when that frame is
/// heard on the sending Mac. The receiving Mac plays every frame at that same moment: it asks the
/// sender for its clock several times a second, and resends requests for lost packets.
enum StreamPacket {
    static let audio: UInt8 = 1, resend: UInt8 = 2, clockRequest: UInt8 = 3, clockAnswer: UInt8 = 4
    static let frames = 240
    /// The sender halves the sound before the 16-bit conversion so peaks up to twice full scale
    /// (a float stream may exceed 1) survive; the receiver doubles it back.
    static let headroom: Float = 2
}

/// Sends the captured sound of `engine` to the receiver. The receiver's address is the source of
/// the latest authentic clock request, so nothing is sent before the receiver asks.
public final class StreamSender: @unchecked Sendable {
    /// Gain the receiver applies (the main volume), linear.
    public let gain = AtomicFloat(1)
    public var port: UInt16 { socket.port }
    public let streamID = UInt32.random(in: 1...UInt32.max)

    /// The session keys it sends with.
    public let crypto: DatagramCrypto
    private let engine: Engine
    private let socket: UDPSocket
    private let running = Atomic<Bool>(true)
    private let lock = NSLock()
    private var destination: sockaddr_in?
    /// Recent packets by packet index, for resending.
    private var backlog = [Int: [UInt8]]()
    private static let backlogPackets = 400   // 2 s

    public init(engine: Engine, crypto: DatagramCrypto, port: UInt16 = 0) throws {
        self.engine = engine
        self.crypto = crypto
        socket = try UDPSocket(port: port)
    }

    public func start() {
        let send = Thread { [self] in sendLoop() }
        send.qualityOfService = .userInteractive
        send.name = "duet.stream.send"
        send.start()
        let receive = Thread { [self] in receiveLoop() }
        receive.qualityOfService = .userInteractive
        receive.name = "duet.stream.requests"
        receive.start()
    }

    public func stop() { running.store(false, ordering: .relaxed) }

    private func sendLoop() {
        let ring = engine.ring
        let count = StreamPacket.frames
        var next: Int?
        var floats = [Float](repeating: 0, count: count * 2)
        var dither = UInt32(truncatingIfNeeded: mach_absolute_time()) | 1
        while running.load(ordering: .relaxed) {
            Thread.sleep(forTimeInterval: 0.002)
            lock.lock()
            let destination = self.destination
            lock.unlock()
            guard let destination else { continue }
            let written = ring.writeIndex
            if next == nil || written - next! > ring.capacity / 2 { next = written - written % count }
            while next! + count <= written {
                let frame = next!
                next = frame + count
                let ok = floats.withUnsafeMutableBufferPointer { ring.read(at: frame, frames: count, into: $0.baseAddress!) }
                guard ok, let heardAt = engine.heardTime(ofFrame: frame) else { continue }
                var payload = ByteWriter()
                payload.put(streamID)
                payload.put(Int64(frame))
                payload.put(heardAt)
                payload.put(gain.value)
                payload.put(Float(engine.sampleRate))
                payload.bytes.reserveCapacity(payload.bytes.count + count * 4)
                for x in floats {
                    // TPDF dither: the sum of two uniform values, one step wide each.
                    dither ^= dither << 13; dither ^= dither >> 17; dither ^= dither << 5
                    let a = Float(dither & 0xFFFF) / 65536, b = Float(dither >> 16) / 65536
                    let scaled = x / StreamPacket.headroom * 32767 + (a - b)
                    payload.put(Int16(max(-32768, min(32767, scaled.rounded()))))
                }
                let packet = crypto.seal(StreamPacket.audio, payload.bytes)
                socket.send(packet, to: destination)
                let index = frame / count
                lock.lock()
                backlog[index] = packet
                backlog[index - Self.backlogPackets] = nil
                lock.unlock()
            }
        }
    }

    private func receiveLoop() {
        while running.load(ordering: .relaxed) {
            guard let (bytes, from, arrival) = socket.receive(timeout: 0.25), let (type, payload) = crypto.open(bytes) else { continue }
            var reader = ByteReader(payload)
            switch type {
            case StreamPacket.clockRequest:
                guard let t1 = reader.double() else { continue }
                lock.lock()
                destination = from
                lock.unlock()
                var answer = ByteWriter()
                answer.put(t1)
                answer.put(arrival)
                answer.put(HostClock.now)
                socket.send(crypto.seal(StreamPacket.clockAnswer, answer.bytes), to: from)
            case StreamPacket.resend:
                guard reader.get(UInt32.self) == streamID, let n = reader.get(UInt16.self) else { continue }
                for _ in 0..<n {
                    guard let index = reader.get(Int64.self) else { break }
                    lock.lock()
                    let packet = backlog[Int(index)]
                    lock.unlock()
                    if let packet { socket.send(packet, to: from) }
                }
            default: break
            }
        }
    }
}

/// Receives the other Mac's stream and renders it for `Engine` at the right moment.
/// Network thread: stores packets, keeps the clock model, asks for lost packets.
/// IO thread (`render`): finds the source position for each output frame and resamples.
public final class StreamReceiver: @unchecked Sendable {
    public struct Stats: Sendable {
        public var packets = 0
        public var resent = 0
        /// Output frames played as silence because their packet was missing.
        public var concealed = 0
        /// Playback position resets (start, or an error beyond 10 ms).
        public var jumps = 0
        /// Lowest time (seconds) between a packet's arrival and the moment it was needed, since the last read.
        public var minMargin = Double.infinity
        public var roundTrip = 0.0
        public var offset = 0.0
        public var drift = 0.0
        /// Playback position minus the ideal one, seconds (the correction loop's error).
        public var error = 0.0
    }

    private struct Mapping: BitwiseCopyable {
        var stream: UInt32
        var frame: Int        // first frame of the newest packet
        var time: Double      // when `frame` is heard on the sender (sender host seconds)
        var rate: Double      // sender frames per second
        var gain: Float
        var clock: ClockSync.Model
    }

    private let crypto: DatagramCrypto
    private let socket: UDPSocket
    private let source: sockaddr_in
    private let running = Atomic<Bool>(true)

    // Packet store: slot = packet index modulo `slots`; a slot's tag is the packet index it holds
    // (-1 while being written), checked before and after a read.
    private static let slots = 512
    private let store: UnsafeMutablePointer<Float>
    private let tags: UnsafeMutablePointer<Atomic<Int64>>
    private let mapping = SeqLock<Mapping?>(nil)

    // Network thread only.
    private var clock = ClockSync()
    private var stream: UInt32 = 0
    private var newest: Mapping?
    private var highest = -1
    private var missing = [Int: (first: Double, asked: Double)]()
    private var arrivals = [Int: Double]()   // packet index -> arrival, for the margin

    // IO thread only.
    private var outputRate = 48_000.0
    private var interpolator = Interpolator()
    private let input: UnsafeMutablePointer<Float>
    private static let inputCapacity = 20_000
    private var position: Double?
    private var integral = 0.0
    private var lastGain: Float = 0
    private var playingStream: UInt32 = 0

    // Shared statistics.
    private let statsLock = NSLock()
    private var stats = Stats()

    public init(crypto: DatagramCrypto, source ip: String, port: UInt16) throws {
        self.crypto = crypto
        socket = try UDPSocket()
        self.source = UDPSocket.address(ip, port)
        store = .allocate(capacity: Self.slots * StreamPacket.frames * 2)
        store.initialize(repeating: 0, count: Self.slots * StreamPacket.frames * 2)
        tags = .allocate(capacity: Self.slots)
        for i in 0..<Self.slots { (tags + i).initialize(to: Atomic(-1)) }
        input = .allocate(capacity: Self.inputCapacity * 2)
    }

    deinit {
        store.deallocate()
        tags.deallocate()
        input.deallocate()
    }

    /// Called by the engine before it starts (not realtime).
    func prepare(outputRate: Double, sourceRate: Double) {
        self.outputRate = outputRate
        interpolator = Interpolator(ratio: sourceRate / outputRate)
    }

    public func start() {
        let thread = Thread { [self] in networkLoop() }
        thread.qualityOfService = .userInteractive
        thread.name = "duet.stream.receive"
        thread.start()
    }

    public func stop() { running.store(false, ordering: .relaxed) }

    /// Seconds since the last audio packet arrived (infinity before the first).
    public var silence: Double {
        statsLock.lock(); defer { statsLock.unlock() }
        return lastPacket.map { HostClock.now - $0 } ?? .infinity
    }
    private var lastPacket: Double?

    /// Returns the statistics and starts a new margin window.
    public func takeStats() -> Stats {
        statsLock.lock(); defer { statsLock.unlock() }
        let s = stats
        stats.minMargin = .infinity
        return s
    }

    // MARK: Network thread

    private func networkLoop() {
        var nextRequest = 0.0
        let started = HostClock.now
        while running.load(ordering: .relaxed) {
            let now = HostClock.now
            if now >= nextRequest {
                var request = ByteWriter()
                request.put(HostClock.now)
                socket.send(crypto.seal(StreamPacket.clockRequest, request.bytes), to: source)
                // A fast burst at first, then a steady 50 per second that also keeps both radios awake.
                nextRequest = now + (now - started < 3 ? 0.01 : 0.02)
            }
            askForMissing(now: now)
            guard let (bytes, _, arrival) = socket.receive(timeout: max(0.001, nextRequest - HostClock.now)),
                  let (type, payload) = crypto.open(bytes) else { continue }
            var reader = ByteReader(payload)
            switch type {
            case StreamPacket.audio: receiveAudio(&reader, arrival: arrival)
            case StreamPacket.clockAnswer:
                guard let t1 = reader.double(), let t2 = reader.double(), let t3 = reader.double() else { continue }
                clock.add(t1: t1, t2: t2, t3: t3, t4: arrival)
                publish()
                statsLock.lock()
                stats.roundTrip = clock.minRoundTrip
                if let model = clock.model { stats.offset = model.offset(at: arrival); stats.drift = model.drift }
                statsLock.unlock()
            default: break
            }
        }
    }

    private func receiveAudio(_ reader: inout ByteReader, arrival: Double) {
        guard let id = reader.get(UInt32.self), let frame64 = reader.get(Int64.self), let time = reader.double(),
              let gain = reader.float(), let rate = reader.float() else { return }
        let frame = Int(frame64)
        let count = StreamPacket.frames
        guard frame >= 0, frame % count == 0 else { return }
        if id != stream {
            // A new stream (the sender restarted): forget the old one's packets.
            stream = id
            highest = -1
            missing.removeAll()
            arrivals.removeAll()
            for i in 0..<Self.slots { tags[i].store(-1, ordering: .relaxed) }
        }
        let index = frame / count
        if highest >= 0, index <= highest - Self.slots / 2 { return }   // far too old
        let slot = index % Self.slots
        guard tags[slot].load(ordering: .relaxed) != Int64(index) else { return }   // duplicate
        tags[slot].store(-1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        let samples = store + slot * count * 2
        for i in 0..<(count * 2) {
            samples[i] = Float(reader.get(Int16.self) ?? 0) / 32767 * StreamPacket.headroom
        }
        tags[slot].store(Int64(index), ordering: .releasing)

        let recovered = missing.removeValue(forKey: index) != nil
        if index > highest {
            if highest >= 0, index - highest <= Self.slots / 2 {
                for lost in (highest + 1)..<index { missing[lost] = (arrival, 0) }
            }
            highest = index
            newest = Mapping(stream: id, frame: frame, time: time, rate: Double(rate), gain: gain,
                             clock: clock.model ?? ClockSync.Model(time: 0, offset: 0, drift: 0))
            publish()
        }
        arrivals[index] = arrival
        arrivals[index - Self.slots] = nil
        statsLock.lock()
        stats.packets += 1
        if recovered { stats.resent += 1 }
        lastPacket = arrival
        statsLock.unlock()
    }

    private func publish() {
        guard var m = newest, let model = clock.model else { return }
        m.clock = model
        mapping.store(m)
    }

    /// Asks again for each missing packet every 20 ms until it arrives or is a second old.
    private func askForMissing(now: Double) {
        guard !missing.isEmpty else { return }
        var due = [Int]()
        for (index, entry) in missing {
            if now - entry.first > 1 { missing[index] = nil; continue }
            if now - entry.asked >= 0.02 && now - entry.first >= 0.002 { due.append(index) }
        }
        guard !due.isEmpty else { return }
        var request = ByteWriter()
        request.put(stream)
        request.put(UInt16(min(due.count, 100)))
        for index in due.sorted().prefix(100) {
            request.put(Int64(index))
            missing[index]?.asked = now
        }
        socket.send(crypto.seal(StreamPacket.resend, request.bytes), to: source)
    }

    // MARK: IO thread

    /// Writes `frames` stereo frames to `output`: the sound to be heard from host time `heardAt` (seconds)
    /// on this Mac's main output, one frame per output sample. Silence until the stream and clock are known.
    func render(frames: Int, heardAt: Double?, into output: UnsafeMutablePointer<Float>) {
        guard let m = mapping.load(), let heardAt else {
            output.update(repeating: 0, count: frames * 2)
            position = nil
            return
        }
        // Where the sender is in its stream at that moment, in its frames.
        let sourceTime = heardAt + m.clock.offset(at: heardAt)
        let target = Double(m.frame) + (sourceTime - m.time) * m.rate
        let nominal = m.rate / outputRate
        if m.stream != playingStream || position == nil || abs(target - position!) > 0.01 * m.rate {
            if statsLock.try() { stats.jumps += 1; statsLock.unlock() }
            position = target
            integral = 0
            playingStream = m.stream
        }
        // PI loop on the position error (seconds), within +-1000 ppm: about 4 s to settle, no pitch change heard.
        let error = (target - position!) / m.rate
        let dt = Double(frames) / outputRate
        integral = max(-5e-4, min(5e-4, integral + 0.0625 * error * dt))
        let correction = max(-1e-3, min(1e-3, 0.5 * error + integral))
        let step = nominal * (1 + correction)

        let half = Interpolator.half
        let first = Int(position!.rounded(.down)) - half + 1
        let last = Int((position! + Double(frames - 1) * step).rounded(.down)) + half
        let span = last - first + 1
        guard span <= Self.inputCapacity, frames * 2 <= Self.inputCapacity * 2 else {
            output.update(repeating: 0, count: frames * 2)
            position = nil
            return
        }
        let concealed = gather(first: first, count: span)
        interpolator.render(input: input, inputStart: first, start: position!, step: step, count: frames,
                            gain: (lastGain, m.gain), into: output)
        lastGain = m.gain
        position! += Double(frames) * step

        // Margin: how long before this moment the last frame needed here arrived. Approximated from the
        // newest packet: it is ahead of the last needed frame by (newest end - last) frames.
        let margin = Double(m.frame + StreamPacket.frames - 1 - last) / m.rate
        if statsLock.try() {
            stats.minMargin = min(stats.minMargin, margin)
            stats.concealed += concealed > 0 ? frames : 0
            stats.error = error
            statsLock.unlock()
        }
    }

    /// Copies source frames [first, first + count) into `input`, silence where a packet is missing.
    /// Returns the number of missing frames.
    private func gather(first: Int, count: Int) -> Int {
        let size = StreamPacket.frames
        var done = 0, missingFrames = 0
        while done < count {
            let frame = first + done
            let destination = input + done * 2
            if frame < 0 {
                let n = min(count - done, -frame)
                destination.update(repeating: 0, count: n * 2)
                missingFrames += n
                done += n
                continue
            }
            let index = frame / size, offset = frame % size
            let n = min(count - done, size - offset)
            let slot = index % Self.slots
            var ok = tags[slot].load(ordering: .acquiring) == Int64(index)
            if ok {
                destination.update(from: store + (slot * size + offset) * 2, count: n * 2)
                atomicMemoryFence(ordering: .acquiring)
                ok = tags[slot].load(ordering: .relaxed) == Int64(index)
            }
            if !ok {
                destination.update(repeating: 0, count: n * 2)
                missingFrames += n
            }
            done += n
        }
        return missingFrames
    }
}
