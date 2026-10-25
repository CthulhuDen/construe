import Accelerate

/// The last few seconds of sound, as 16 kHz mono samples, overwriting the oldest ones when full.
///
/// Near-silence doesn't advance the buffer: of each silent gap only the first `maxKeptSilence` is
/// kept, enough for the recognizer to tell phrases apart, and it's held aside until sound resumes,
/// so a paused video neither pushes the last phrase out of the buffer nor takes up its tail.
nonisolated struct AudioRingBuffer {
    static let sampleRate: Double = 16_000
    /// Length of the frames whose loudness decides between sound and silence.
    static let frameDuration: Double = 0.02
    /// RMS level below which a frame counts as silence: about −55 dBFS, so only near-silence such as
    /// paused playback is dropped, while quiet speech and background music are kept.
    static let silenceThreshold: Float = 0.0018
    /// The longest stretch of any silent gap that is kept.
    static let maxKeptSilence: Double = 1

    private static let frameLength = Int(sampleRate * frameDuration)
    private static let maxKeptSilentSamples = Int(sampleRate * maxKeptSilence)

    private var storage: [Float]
    private var writeIndex = 0
    private var count = 0
    /// The kept start of the current silent gap, written to the buffer only once sound follows it.
    private var pendingSilence: [Float] = []
    /// Whether any sound has been written. Sound is never overwritten by silence alone, because
    /// silence is written only ahead of sound.
    private(set) var hasSound = false

    /// `capacity` is in samples.
    init(capacity: Int) {
        storage = [Float](repeating: 0, count: max(capacity, 1))
        pendingSilence.reserveCapacity(Self.maxKeptSilentSamples)
    }

    var isEmpty: Bool { count == 0 }

    /// Appends `samples`, dropping silence beyond `maxKeptSilence`. Returns whether they contained sound.
    @discardableResult
    mutating func append(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        guard let base = samples.baseAddress else { return false }
        var heardSound = false
        var offset = 0
        while offset < samples.count {
            let length = min(Self.frameLength, samples.count - offset)
            var rms: Float = 0
            vDSP_rmsqv(base + offset, 1, &rms, vDSP_Length(length))
            let frame = UnsafeBufferPointer(start: base + offset, count: length)
            if rms < Self.silenceThreshold {
                if pendingSilence.count + length <= Self.maxKeptSilentSamples {
                    pendingSilence.append(contentsOf: frame)
                }
            } else {
                heardSound = true
                hasSound = true
                pendingSilence.withUnsafeBufferPointer { write($0) }
                pendingSilence.removeAll(keepingCapacity: true)
                write(frame)
            }
            offset += length
        }
        return heardSound
    }

    /// The kept samples, oldest first, without the silence after the last sound.
    func snapshot() -> [Float] {
        guard count == storage.count else { return Array(storage[..<count]) }
        return Array(storage[writeIndex...] + storage[..<writeIndex])
    }

    private mutating func write(_ frame: UnsafeBufferPointer<Float>) {
        for sample in frame {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % storage.count
        }
        count = min(count + frame.count, storage.count)
    }
}
