import Foundation
import Synchronization

/// Single-producer, single-consumer ring of interleaved stereo Float32 frames.
/// The producer (the realtime IO thread) never blocks and never waits: if the consumer falls
/// more than `capacity` frames behind, the consumer skips ahead and sees a gap in frame indices.
public final class FrameRing: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total frames ever written. The index of a frame is its position in this count.
    private let written = Atomic<Int>(0)

    public init(capacityFrames: Int) {
        var c = 1
        while c < capacityFrames { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c * 2)
        storage.initialize(repeating: 0, count: c * 2)
    }

    deinit { storage.deallocate() }

    public var writeIndex: Int { written.load(ordering: .acquiring) }

    /// Producer side. Realtime safe.
    public func write(_ source: UnsafePointer<Float>, frames: Int) {
        let start = written.load(ordering: .relaxed)
        var done = 0
        while done < frames {
            let pos = (start + done) & mask
            let n = min(frames - done, capacity - pos)
            (storage + pos * 2).update(from: source + done * 2, count: n * 2)
            done += n
        }
        written.store(start + frames, ordering: .releasing)
    }

    /// Producer side: write silence (used when the capture side delivers no buffer).
    public func writeSilence(frames: Int) {
        let start = written.load(ordering: .relaxed)
        var done = 0
        while done < frames {
            let pos = (start + done) & mask
            let n = min(frames - done, capacity - pos)
            (storage + pos * 2).update(repeating: 0, count: n * 2)
            done += n
        }
        written.store(start + frames, ordering: .releasing)
    }

    /// Consumer side. Copies frames [index, index + frames) if they are still in the ring.
    /// Returns false if they were overwritten (consumer too slow) or are not written yet.
    public func read(at index: Int, frames: Int, into destination: UnsafeMutablePointer<Float>) -> Bool {
        let end = written.load(ordering: .acquiring)
        guard index >= 0, index + frames <= end, index >= end - capacity else { return false }
        var done = 0
        while done < frames {
            let pos = (index + done) & mask
            let n = min(frames - done, capacity - pos)
            (destination + done * 2).update(from: storage + pos * 2, count: n * 2)
            done += n
        }
        // The producer may have lapped us during the copy.
        return written.load(ordering: .acquiring) - capacity <= index
    }
}

/// Lock-free latest value, written by one thread (possibly the realtime IO thread) and read by
/// others without ever blocking the writer (seqlock: a reader retries if a write overlapped).
public final class SeqLock<Value: BitwiseCopyable>: @unchecked Sendable {
    private let sequence = Atomic<UInt64>(0)
    private let storage: UnsafeMutablePointer<Value>

    public init(_ value: Value) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: value)
    }

    deinit { storage.deallocate() }

    public func store(_ value: Value) {
        let s = sequence.load(ordering: .relaxed)
        sequence.store(s &+ 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        storage.pointee = value
        sequence.store(s &+ 2, ordering: .releasing)
    }

    public func load() -> Value {
        while true {
            let s1 = sequence.load(ordering: .acquiring)
            if s1 & 1 == 1 { continue }
            let value = storage.pointee
            atomicMemoryFence(ordering: .acquiring)
            if sequence.load(ordering: .relaxed) == s1 { return value }
        }
    }
}

/// Float stored in an atomic, for values the UI writes and the IO thread reads.
public final class AtomicFloat: @unchecked Sendable {
    private let bits: Atomic<UInt32>
    public init(_ value: Float) { bits = Atomic(value.bitPattern) }
    public var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}
