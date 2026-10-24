import Accelerate
import AVFoundation
import Observation
import OSLog

/// Caught audio shown under the input as a waveform, so the transcript's source is visible and can be replayed.
struct AudioClip {
    /// Bars in the waveform thumbnail.
    static let levelCount = 60

    let samples: [Float]
    let sampleRate: Double
    /// Peak level per bar, 0...1, scaled so the loudest bar is full height.
    let levels: [Float]

    init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
        levels = Self.levels(of: samples, count: Self.levelCount)
    }

    var duration: Double {
        Double(samples.count) / sampleRate
    }

    /// Splits `samples` into `count` equal parts and returns each part's peak, normalized to the loudest.
    static func levels(of samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return [] }
        let peaks = (0..<count).map { index in
            let start = samples.count * index / count
            let end = max(samples.count * (index + 1) / count, start + 1)
            var peak: Float = 0
            samples[start..<min(end, samples.count)].withUnsafeBufferPointer { part in
                if let base = part.baseAddress {
                    vDSP_maxmgv(base, 1, &peak, vDSP_Length(part.count))
                }
            }
            return peak
        }
        let loudest = peaks.max() ?? 0
        guard loudest > 0 else { return peaks }
        return peaks.map { $0 / loudest }
    }
}

/// Plays an `AudioClip` through the default output. Construe's own audio is excluded from
/// listening, so replaying doesn't feed back into the buffer.
///
/// One player lives for the app's lifetime and creates its engine on the first replay: creating
/// and destroying an engine with every popup touched Core Audio in-process and made the
/// listening tap skip an IO cycle. The engine is bound to the output device it started on, so it's
/// dropped when the audio configuration changes (e.g. a new output device) and recreated on the
/// next replay.
@Observable
final class AudioClipPlayer {
    private(set) var isPlaying = false

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private let node = AVAudioPlayerNode()
    /// Identifies the current playback, so a stopped one's completion doesn't stop the next.
    @ObservationIgnored private var generation = 0

    func toggle(_ clip: AudioClip) {
        isPlaying ? stop() : play(clip)
    }

    func play(_ clip: AudioClip) {
        guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        clip.samples.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(clip.samples.count)

        let engine = self.engine ?? makeEngine()
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            Logger.audio.error("Playback failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        generation += 1
        let current = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == current else { return }
                stop()
            }
        }
        node.play()
        isPlaying = true
    }

    func stop() {
        guard isPlaying else { return }
        node.stop()
        engine?.stop()
        isPlaying = false
    }

    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        engine.attach(node)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropEngine() }
        }
        self.engine = engine
        return engine
    }

    /// Stops any playback and releases the engine; the next replay creates one on the current output.
    private func dropEngine() {
        Logger.audio.debug("Audio configuration changed; replay engine released")
        stop()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            engine.detach(node)
        }
        engine = nil
    }
}
