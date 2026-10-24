import AVFoundation
import Foundation
import Testing
@testable import Construe

/// Renders test speech in code, so no audio fixtures need to live in the repository.
enum TestSpeech {
    struct RenderError: Error {}

    /// `text` spoken by an English system voice, as 16 kHz mono samples.
    @MainActor
    static func render(_ text: String) async throws -> [Float] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let buffers: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            var collected: [AVAudioPCMBuffer] = []
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished, let buffer = buffer as? AVAudioPCMBuffer else { return }
                // An empty buffer marks the end.
                if buffer.frameLength == 0 {
                    finished = true
                    continuation.resume(returning: collected)
                } else {
                    collected.append(buffer)
                }
            }
        }
        withExtendedLifetime(synthesizer) {}

        guard let first = buffers.first,
              let target = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: AudioRingBuffer.sampleRate, channels: 1, interleaved: false),
              let converter = PCMConverter(from: first.format, to: target)
        else { throw RenderError() }
        var samples: [Float] = []
        for (index, buffer) in buffers.enumerated() {
            let output = try converter.convert(buffer, endOfStream: index == buffers.count - 1)
            guard let channel = output.floatChannelData?[0] else { throw RenderError() }
            samples += UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        }
        return samples
    }
}

@Suite(.tags(.integration))
@MainActor
struct AudioTranscriberTests {
    private static let phrase = "The library opens at nine tomorrow morning."

    private func makeTranscriber() async throws -> AudioTranscriber {
        let transcriber = AudioTranscriber(locale: Locale(identifier: "en_US"))
        try await transcriber.prepare()
        return transcriber
    }

    @Test func transcribesSpeech() async throws {
        let samples = try await TestSpeech.render(Self.phrase)
        let text = try await makeTranscriber().transcribe(samples, sampleRate: AudioRingBuffer.sampleRate)
        #expect(text.lowercased().contains("library"))
    }

    @Test func transcribesSpeechThroughRingBuffer() async throws {
        let speech = try await TestSpeech.render(Self.phrase)
        let gap = [Float](repeating: 0, count: 3 * Int(AudioRingBuffer.sampleRate))
        var buffer = AudioRingBuffer(capacity: 30 * Int(AudioRingBuffer.sampleRate))
        for part in [speech, gap, speech] {
            part.withUnsafeBufferPointer { _ = buffer.append($0) }
        }

        let text = try await makeTranscriber().transcribe(buffer.snapshot(), sampleRate: AudioRingBuffer.sampleRate)
        #expect(text.lowercased().contains("library"))
    }
}

@MainActor
struct TranslationSessionTranscriptTests {
    private struct StubError: LocalizedError {
        var errorDescription: String? { "Stub failure" }
    }

    private static let samples = [Float](repeating: 0.1, count: 16_000)

    private func makeSession() throws -> TranslationSession {
        let defaults = try #require(UserDefaults(suiteName: "SessionTranscriptTests-\(UUID().uuidString)"))
        return TranslationSession(settings: AppSettings(defaults: defaults), apiKey: { nil })
    }

    private func attach(to session: TranslationSession, _ transcribe: ([Float]) async throws -> String) async {
        await session.attachAudio(Self.samples, sampleRate: 16_000, transcribe: transcribe)
    }

    @Test func transcriptFillsEmptyInput() async throws {
        let session = try makeSession()
        await attach(to: session) { _ in "¿Dónde está?" }
        #expect(session.input == "¿Dónde está?")
        #expect(session.audioClip?.duration == 1)
        #expect(session.audioNotice == nil)
        #expect(session.isTranscribing == false)
    }

    @Test func transcriptIsAppendedToExistingInput() async throws {
        let session = try makeSession()
        session.input = "Context: "
        await attach(to: session) { _ in "hola" }
        #expect(session.input == "Context: hola")
    }

    @Test func emptyTranscriptShowsNotice() async throws {
        let session = try makeSession()
        await attach(to: session) { _ in "" }
        #expect(session.input.isEmpty)
        #expect(session.audioNotice == "No speech recognized.")
        #expect(session.isTranscribing == false)
    }

    @Test func errorShowsItsMessage() async throws {
        let session = try makeSession()
        await attach(to: session) { _ in throw StubError() }
        #expect(session.audioNotice == "Stub failure")
        #expect(session.isTranscribing == false)
    }

    @Test func clearInputClearsAudioClipAndNotice() async throws {
        let session = try makeSession()
        await attach(to: session) { _ in "" }
        session.clearInput()
        #expect(session.audioClip == nil)
        #expect(session.audioNotice == nil)
    }
}

@MainActor
struct AudioClipTests {
    @Test func levelsAreNormalizedPeaksPerPart() {
        let samples: [Float] = [0.1, -0.2, 0.0, 0.4, -0.8, 0.2]
        #expect(AudioClip.levels(of: samples, count: 3) == [0.25, 0.5, 1])
    }

    @Test func silentClipHasZeroLevels() {
        let levels = AudioClip.levels(of: [Float](repeating: 0, count: 1000), count: AudioClip.levelCount)
        #expect(levels.count == AudioClip.levelCount)
        #expect(levels.allSatisfy { $0 == 0 })
    }

    @Test func emptyClipHasNoLevels() {
        #expect(AudioClip.levels(of: [], count: 10).isEmpty)
    }
}
