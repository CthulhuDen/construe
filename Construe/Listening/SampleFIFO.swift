import Darwin
import Synchronization

/// A lock-free queue of mono samples from one producer (the HAL's real-time IO thread) to one
/// consumer (a background queue).
///
/// The producer side never blocks, allocates or takes a lock, so it's safe on the real-time thread:
/// it copies into preallocated storage and publishes the new end with an atomic store. When the
/// consumer falls behind by the whole capacity, new samples are dropped and counted rather than
/// waiting for room.
nonisolated final class SampleFIFO: @unchecked Sendable {
    let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    /// Total samples written and read since creation; their difference is the fill level.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    /// `CLOCK_UPTIME_RAW` time of the last `write`, for the stall watchdog.
    private let lastWrite = Atomic<UInt64>(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    /// Channel count of the last write, for diagnostics.
    private let lastChannels = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deallocate()
    }

    // MARK: Producer (real-time thread)

    /// Appends `frames` frames of interleaved `channels`-channel audio, mixed down to mono.
    /// Real-time safe.
    func write(interleaved samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        lastWrite.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
        lastChannels.store(channels, ordering: .relaxed)
        guard frames > 0, channels > 0 else { return }

        let end = written.load(ordering: .relaxed)
        let free = capacity - (end - read.load(ordering: .acquiring))
        let count = min(frames, free)
        if count < frames {
            dropped.add(frames - count, ordering: .relaxed)
        }
        guard count > 0 else { return }

        var index = end % capacity
        if channels == 1 {
            let first = min(count, capacity - index)
            (storage + index).update(from: samples, count: first)
            if count > first {
                storage.update(from: samples + first, count: count - first)
            }
        } else {
            let scale = 1 / Float(channels)
            for frame in 0..<count {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                storage[index] = sum * scale
                index = index + 1 == capacity ? 0 : index + 1
            }
        }
        written.store(end + count, ordering: .releasing)
    }

    /// Records a callback without samples, so the watchdog still sees the IO thread running.
    func markAlive() {
        lastWrite.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
    }

    // MARK: Consumer

    /// Moves up to `maxCount` samples into `destination`, oldest first, and returns how many.
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let start = read.load(ordering: .relaxed)
        let available = written.load(ordering: .acquiring) - start
        let count = min(available, maxCount)
        guard count > 0 else { return 0 }

        let index = start % capacity
        let first = min(count, capacity - index)
        destination.update(from: storage + index, count: first)
        if count > first {
            (destination + first).update(from: storage, count: count - first)
        }
        read.store(start + count, ordering: .releasing)
        return count
    }

    /// Samples dropped because the queue was full, since the last call.
    func takeDroppedCount() -> Int {
        dropped.exchange(0, ordering: .relaxed)
    }

    /// Time since the producer last ran.
    var timeSinceLastWrite: Duration {
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- lastWrite.load(ordering: .relaxed)
        return .nanoseconds(Int64(min(elapsed, UInt64(Int64.max))))
    }

    /// Channel count the producer last saw, or 0 before the first write.
    var channels: Int {
        lastChannels.load(ordering: .relaxed)
    }
}
