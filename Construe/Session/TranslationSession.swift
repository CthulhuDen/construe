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
    private(set) var response = ""
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
            fastMode: settings.fastMode
        )
        task?.cancel()
        response = ""
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

    func cancel() {
        task?.cancel()
        task = nil
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
