import AVFoundation
import Foundation
import Testing
@testable import Construe

@MainActor
struct AudioRingBufferTests {
    private static let second = Int(AudioRingBuffer.sampleRate)

    private func sine(seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * AudioRingBuffer.sampleRate)).map { index in
            amplitude * sin(2 * .pi * 440 * Float(index) / Float(AudioRingBuffer.sampleRate))
        }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * AudioRingBuffer.sampleRate))
    }

    @discardableResult
    private func append(_ samples: [Float], to buffer: inout AudioRingBuffer) -> Bool {
        samples.withUnsafeBufferPointer { buffer.append($0) }
    }

    @Test func soundPassesThrough() {
        var buffer = AudioRingBuffer(capacity: 2 * Self.second)
        let sound = sine(seconds: 1)
        append(sound, to: &buffer)
        #expect(buffer.snapshot() == sound)
        #expect(buffer.hasSound)
    }

    @Test func wrappingKeepsNewestSamplesInOrder() {
        var buffer = AudioRingBuffer(capacity: 1000)
        let sound = sine(seconds: 0.3)
        append(sound, to: &buffer)
        #expect(buffer.snapshot() == Array(sound.suffix(1000)))
    }

    @Test func longSilentGapKeepsOneSecond() {
        var buffer = AudioRingBuffer(capacity: 10 * Self.second)
        append(sine(seconds: 1), to: &buffer)
        append(silence(seconds: 5), to: &buffer)
        append(sine(seconds: 1), to: &buffer)

        let snapshot = buffer.snapshot()
        #expect(snapshot.count == 3 * Self.second)
        #expect(snapshot[Self.second..<(2 * Self.second)].allSatisfy { $0 == 0 })
    }

    @Test func trailingSilenceTakesNoSpace() {
        var buffer = AudioRingBuffer(capacity: 2 * Self.second)
        let sound = sine(seconds: 3)
        append(sound, to: &buffer)
        append(silence(seconds: 0.5), to: &buffer)
        #expect(buffer.snapshot() == Array(sound.suffix(2 * Self.second)))
    }

    @Test func soundAfterLongSilenceResumesWriting() {
        var buffer = AudioRingBuffer(capacity: 10 * Self.second)
        append(silence(seconds: 5), to: &buffer)
        let sound = sine(seconds: 2)
        append(sound, to: &buffer)
        #expect(Array(buffer.snapshot().suffix(sound.count)) == sound)
    }

    @Test func appendReportsSoundOrSilence() {
        var buffer = AudioRingBuffer(capacity: 2 * Self.second)
        #expect(append(silence(seconds: 0.5), to: &buffer) == false)
        #expect(buffer.hasSound == false)
        #expect(append(sine(seconds: 0.5), to: &buffer))
    }

    @Test func quietSoundIsKept() {
        var buffer = AudioRingBuffer(capacity: 10 * Self.second)
        // About −43 dBFS RMS: quiet speech, well above the silence threshold.
        let quiet = sine(seconds: 3, amplitude: 0.01)
        #expect(append(quiet, to: &buffer))
        #expect(buffer.snapshot() == quiet)
    }

    /// The tap delivers audio at the device rate; it reaches the buffer resampled to 16 kHz.
    @Test func deviceRateAudioIsResampledTo16kHz() throws {
        let format48k = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let format16k = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioRingBuffer.sampleRate, channels: 1, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format48k, frameCapacity: 48_000))
        let channel = try #require(input.floatChannelData?[0])
        for index in 0..<48_000 {
            channel[index] = 0.5 * sin(2 * .pi * 440 * Float(index) / 48_000)
        }
        input.frameLength = 48_000

        let converter = try #require(PCMConverter(from: format48k, to: format16k))
        let output = try converter.convert(input, endOfStream: true)
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData?[0], count: Int(output.frameLength)))

        #expect(abs(samples.count - Self.second) < 100)
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        #expect(abs(rms - 0.5 / sqrt(2)) < 0.02)
    }

    /// Interleaved stereo is mixed down to mono, not read as twice as many mono samples.
    @Test func interleavedStereoKeepsItsDuration() throws {
        let stereo = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let mono16k = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioRingBuffer.sampleRate, channels: 1, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 48_000))
        let interleaved = try #require(input.floatChannelData?[0])
        for frame in 0..<48_000 {
            let sample = 0.5 * sin(2 * .pi * 440 * Float(frame) / 48_000)
            interleaved[2 * frame] = sample
            interleaved[2 * frame + 1] = sample
        }
        input.frameLength = 48_000

        let converter = try #require(PCMConverter(from: stereo, to: mono16k))
        let output = try converter.convert(input, endOfStream: true)
        #expect(abs(Int(output.frameLength) - Self.second) < 100)
    }

    @Test func newBufferIsEmpty() {
        let buffer = AudioRingBuffer(capacity: Self.second)
        #expect(buffer.isEmpty)
        #expect(buffer.snapshot().isEmpty)
        #expect(buffer.hasSound == false)
    }
}
