import AVFoundation
import OSLog
import Speech

/// On-device speech recognition for caught audio, with Apple's `SpeechTranscriber`.
final class AudioTranscriber {
    let locale: Locale

    /// An analyzer with the model already loaded. An analyzer can't be reused once it finishes,
    /// so each transcription takes the spare and a new one is prepared in the background.
    private struct Analyzer {
        let analyzer: SpeechAnalyzer
        let transcriber: SpeechTranscriber
    }

    private var format: AVAudioFormat?
    private var spare: Task<Analyzer, Error>?

    init(locale: Locale) {
        self.locale = locale
    }

    /// Downloads the speech model if needed and loads it, so the first transcription is fast.
    func prepare() async throws {
        // Only a few locales can be reserved at once; free the others so switching languages never hits the limit.
        for reserved in await AssetInventory.reservedLocales
        where reserved.identifier(.bcp47) != locale.identifier(.bcp47) {
            await AssetInventory.release(reservedLocale: reserved)
        }
        let transcriber = makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Logger.audio.info("Downloading the speech model for \(self.locale.identifier, privacy: .public)")
            try await request.downloadAndInstall()
            Logger.audio.info("Speech model installed")
        }
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = try await makeAnalyzer(transcriber)
        spare = Task { analyzer }
    }

    /// Returns the speech in `samples` (mono), with results joined by spaces.
    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String {
        let task = spare ?? Task { try await makeAnalyzer() }
        spare = nil
        // Prepared after this transcription, so loading it doesn't slow this one down.
        defer { spare = Task { try await makeAnalyzer() } }
        let analyzer = try await task.value

        let input = try convert(samples, sampleRate: sampleRate)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()

        let results = Task {
            var parts: [String] = []
            for try await result in analyzer.transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append(text)
                }
            }
            return parts.joined(separator: " ")
        }
        do {
            if let lastSample = try await analyzer.analyzer.analyzeSequence(stream) {
                try await analyzer.analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.analyzer.cancelAndFinishNow()
            }
        } catch {
            results.cancel()
            throw error
        }
        return try await results.value
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    private func makeAnalyzer(_ transcriber: SpeechTranscriber? = nil) async throws -> Analyzer {
        let transcriber = transcriber ?? makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        return Analyzer(analyzer: analyzer, transcriber: transcriber)
    }

    /// Wraps `samples` in a buffer in the analyzer's preferred format.
    private func convert(_ samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw ListeningError.audioConversionFailed }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let format, format != sourceFormat else { return buffer }
        guard let converter = PCMConverter(from: sourceFormat, to: format) else {
            throw ListeningError.audioConversionFailed
        }
        return try converter.convert(buffer, endOfStream: true)
    }
}

/// Converts PCM audio between formats. Resampler state carries over between calls, so a stream
/// converted chunk by chunk joins up smoothly.
nonisolated final class PCMConverter {
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        // Mix all channels into fewer instead of dropping the extra ones.
        converter.downmix = outputFormat.channelCount < inputFormat.channelCount
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// `endOfStream` flushes the resampler; the converter can't be used again after that.
    func convert(_ buffer: AVAudioPCMBuffer, endOfStream: Bool = false) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw ListeningError.audioConversionFailed
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw error ?? ListeningError.audioConversionFailed
        }
        return output
    }
}
