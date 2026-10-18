import CoreGraphics
import Foundation
import Observation

/// State of one popup session: the input, the streamed response, and the request in flight.
@Observable
final class TranslationSession {
    enum Phase: Equatable {
        case idle
        case streaming
        case done
        case failed(String)
    }

    var input = ""
    /// PNG of a pasted screenshot, already downscaled for the API.
    private(set) var imagePNG: Data?
    /// True while text is being recognized in a pasted screenshot.
    private(set) var isReadingImage = false
    /// Shown under the screenshot when no text could be recognized.
    private(set) var imageNotice: String?
    private(set) var response = ""
    /// The text that produced `response`; the input is cleared on the next invocation, but the
    /// handoff still needs the phrase.
    private(set) var submittedText = ""
    private(set) var phase = Phase.idle
    /// Shown under a finished response: it didn't end normally (refusal, length limit),
    /// or fast mode was requested but the response doesn't confirm it.
    private(set) var notices: [String] = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let client: AnthropicClient
    @ObservationIgnored private let apiKey: () -> String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        settings: AppSettings,
        client: AnthropicClient = AnthropicClient(),
        apiKey: @escaping () -> String? = { KeychainStore.apiKey.read() }
    ) {
        self.settings = settings
        self.client = client
        self.apiKey = apiKey
    }

    /// Whether the attached screenshot goes to the API (the "Attach screenshot image" setting).
    var sendsImage: Bool {
        settings.sendImage
    }

    /// Clears the input and any attached screenshot, keeping the last reply.
    func clearInput() {
        input = ""
        removeImage()
    }

    func removeImage() {
        imagePNG = nil
        imageNotice = nil
    }

    /// Shows `message` in the screenshot row, e.g. when a screen grab fails.
    func showImageNotice(_ message: String) {
        imageNotice = message
    }

    /// Attaches a pasted screenshot and adds the text recognized in it to the input,
    /// so it can be trimmed to the exact phrase before sending.
    func attachImage(_ image: CGImage) async {
        imagePNG = ImageAttachment.pngData(for: image)
        imageNotice = nil
        isReadingImage = true
        defer { isReadingImage = false }

        do {
            let text = try await TextRecognizer.recognizeText(in: image, language: settings.ocrLanguage)
            guard !text.isEmpty else {
                imageNotice = "No text found in the screenshot."
                return
            }
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            input = trimmed.isEmpty ? text : trimmed + " " + text
        } catch {
            imageNotice = "Couldn't read the screenshot: \(error.localizedDescription)"
        }
    }

    /// Link that continues the exchange in a new claude.ai chat, once there is a finished response.
    var handoffURL: URL? {
        guard phase != .streaming, !response.isEmpty else { return nil }
        let text = ClaudeHandoff.text(template: settings.handoffTemplate, phrase: submittedText, reply: response)
        return ClaudeHandoff.url(projectID: settings.projectID, text: text)
    }

    var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .streaming
    }

    func send() {
        guard canSend else { return }
        guard let apiKey = apiKey(), !apiKey.isEmpty else {
            phase = .failed(ClaudeError.missingAPIKey.localizedDescription)
            return
        }

        let request = MessageRequest(
            model: settings.model,
            effort: settings.effort,
            systemPrompt: settings.systemPrompt,
            text: input,
            imagePNG: settings.sendImage ? imagePNG : nil,
            fastMode: settings.fastMode
        )
        task?.cancel()
        response = ""
        submittedText = input
        notices = []
        phase = .streaming
        let expectsFastMode = request.fastMode && AnthropicClient.fastModeModels.contains(request.model)

        task = Task {
            do {
                var reportedSpeed: String?
                for try await event in client.stream(request, apiKey: apiKey) {
                    switch event {
                    case let .text(chunk):
                        response += chunk
                    case let .speed(speed):
                        reportedSpeed = speed
                    case let .stop(reason):
                        if let notice = Self.notice(forStopReason: reason) {
                            notices.append(notice)
                        }
                    }
                }
                if expectsFastMode && reportedSpeed != "fast" {
                    notices.append(Self.fastModeNotice(reportedSpeed: reportedSpeed))
                }
                phase = .done
            } catch is CancellationError {
                phase = .idle
            } catch let error as URLError where error.code == .cancelled {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private static func fastModeNotice(reportedSpeed: String?) -> String {
        let reported = reportedSpeed.map { "it reports speed “\($0)”" } ?? "it doesn't report a speed"
        return "Fast mode is on, but this response doesn't confirm it: \(reported)."
    }

    private static func notice(forStopReason reason: String?) -> String? {
        switch reason {
        case "max_tokens": "The response hit the length limit and was cut off."
        case "refusal": "Claude declined to answer this request."
        default: nil
        }
    }
}
