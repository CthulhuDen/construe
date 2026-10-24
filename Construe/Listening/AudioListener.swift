import Foundation
import Observation
import OSLog
import Speech

enum ListeningError: LocalizedError {
    case unsupportedLanguage(String)
    case speechUnavailable
    case modelDownloading
    case noSound
    case audioConversionFailed
    case audioDevice(OSStatus)
    case audioStalled

    var errorDescription: String? {
        switch self {
        case let .unsupportedLanguage(name):
            "Speech recognition doesn't support \(name). Choose another language in Settings > Listening."
        case .speechUnavailable:
            "On-device speech recognition isn't available on this Mac."
        case .modelDownloading:
            "The speech model is still downloading. Try again in a moment."
        case .noSound:
            "No sound since listening started. If something is playing, allow Construe in System Settings > "
                + "Privacy & Security > Screen & System Audio Recording, under System Audio Recording Only."
        case .audioConversionFailed:
            "Couldn't convert the audio for speech recognition."
        case let .audioDevice(status):
            "Couldn't capture system audio (error \(status))."
        case .audioStalled:
            "System audio stopped arriving."
        }
    }
}

/// A listening session: system audio kept in a rolling buffer, transcribed on demand by Catch audio.
@Observable
final class AudioListener {
    private(set) var isListening = false
    /// True while the speech model downloads or loads, after listening starts.
    private(set) var isPreparingModel = false
    /// Why listening ended on its own (silence, sleep, revoked permission); `nil` after a manual stop.
    private(set) var stopReason: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var capture: SystemAudioCapture?
    @ObservationIgnored private var transcriber: AudioTranscriber?
    @ObservationIgnored private var modelError: Error?
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?
    @ObservationIgnored private var isStarting = false

    /// How often the auto-stop checks the time since the last sound.
    private static let autoStopInterval = Duration.seconds(30)

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() async throws {
        guard !isListening, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        guard let locale = await resolvedLocale() else {
            throw ListeningError.unsupportedLanguage(Self.languageName(settings.speechLocale))
        }
        guard SpeechTranscriber.isAvailable else { throw ListeningError.speechUnavailable }
        // System audio permission has no public check: macOS asks on the first start, and a denied
        // tap just delivers silence (see `ListeningError.noSound`).

        let capture = SystemAudioCapture(bufferSeconds: settings.listeningBufferSeconds) { [weak self] error in
            self?.stop(reason: "Listening stopped: \(error.localizedDescription)")
        }
        try await capture.start()
        self.capture = capture
        isListening = true
        stopReason = nil
        Logger.audio.info("Listening started, language \(locale.identifier, privacy: .public)")
        prepareTranscriber(for: locale)
        startAutoStop()
    }

    func stop() {
        stop(reason: nil)
    }

    /// Why listening ended on its own, once: later calls return `nil` until it ends on its own again.
    func takeStopReason() -> String? {
        defer { stopReason = nil }
        return stopReason
    }

    /// The buffered sound, while capture keeps running, once the model is ready to transcribe it.
    /// The buffer isn't cleared, so each catch covers the last few seconds.
    func recentAudio() async throws -> [Float] {
        guard let capture else { throw ListeningError.noSound }
        guard let locale = await resolvedLocale() else {
            throw ListeningError.unsupportedLanguage(Self.languageName(settings.speechLocale))
        }
        if let modelError {
            // Retried on the next catch.
            self.modelError = nil
            transcriber = nil
            throw modelError
        }
        guard let transcriber, transcriber.locale.identifier(.bcp47) == locale.identifier(.bcp47) else {
            // The language changed in Settings since listening started.
            prepareTranscriber(for: locale)
            throw ListeningError.modelDownloading
        }
        guard !isPreparingModel else { throw ListeningError.modelDownloading }

        let (samples, hasSound) = capture.snapshot()
        guard hasSound else { throw ListeningError.noSound }
        return samples
    }

    /// Transcribes samples from `recentAudio()`.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let transcriber else { throw ListeningError.modelDownloading }
        let clock = ContinuousClock()
        let start = clock.now
        let text = try await transcriber.transcribe(samples, sampleRate: AudioRingBuffer.sampleRate)
        let milliseconds = Int((clock.now - start) / .milliseconds(1))
        let seconds = Double(samples.count) / AudioRingBuffer.sampleRate
        Logger.audio.info("""
            Transcribed \(seconds, format: .fixed(precision: 1), privacy: .public) s of audio \
            in \(milliseconds, privacy: .public) ms
            """)
        return text
    }

    private func stop(reason: String?) {
        guard isListening else { return }
        autoStopTask?.cancel()
        autoStopTask = nil
        let capture = self.capture
        self.capture = nil
        Task { await capture?.stop() }
        // Dropping the transcriber releases its loaded analyzer, so the model unloads.
        transcriber = nil
        modelError = nil
        isListening = false
        isPreparingModel = false
        stopReason = reason
        Logger.audio.info("Listening stopped\(reason.map { ": \($0)" } ?? "", privacy: .public)")
    }

    /// Downloads and loads the model in the background while capture runs.
    private func prepareTranscriber(for locale: Locale) {
        let transcriber = AudioTranscriber(locale: locale)
        self.transcriber = transcriber
        modelError = nil
        isPreparingModel = true
        Task {
            do {
                try await transcriber.prepare()
                Logger.audio.info("Speech model ready for \(locale.identifier, privacy: .public)")
            } catch {
                Logger.audio.error("Preparing the speech model failed: \(error.localizedDescription, privacy: .public)")
                if self.transcriber === transcriber {
                    modelError = error
                }
            }
            // A stop or a language change may have replaced this transcriber meanwhile.
            if self.transcriber === transcriber {
                isPreparingModel = false
            }
        }
    }

    private func startAutoStop() {
        autoStopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoStopInterval)
                guard let self, let capture = self.capture else { return }
                let minutes = settings.listeningAutoStopMinutes
                if minutes > 0, capture.timeSinceSound >= .seconds(minutes * 60) {
                    stop(reason: "Listening stopped after \(minutes) minutes of silence.")
                    return
                }
            }
        }
    }

    private func resolvedLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Self.requestedLocale(settings.speechLocale))
    }

    /// The stored language, or for `nil` the user's first preferred language. Not `Locale.current`:
    /// Construe is localized only in English, so that would be English with the system region.
    static func requestedLocale(_ identifier: String?) -> Locale {
        Locale(identifier: identifier ?? Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    /// Display name of a stored language identifier, or of the system language for `nil`.
    static func languageName(_ identifier: String?) -> String {
        let identifier = requestedLocale(identifier).identifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
