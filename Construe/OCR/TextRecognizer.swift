import CoreGraphics
import Foundation
import Vision

/// On-device text recognition for pasted screenshots.
enum TextRecognizer {
    /// Returns the text in `image`, with lines joined by spaces (subtitles usually wrap mid-sentence).
    /// `language` is a language identifier such as "es", or `nil` for automatic detection.
    static func recognizeText(in image: CGImage, language: String?) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let language {
            request.recognitionLanguages = [Locale.Language(identifier: language)]
            request.automaticallyDetectsLanguage = false
        } else {
            request.automaticallyDetectsLanguage = true
        }

        let observations = try await request.perform(on: image)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
