import Foundation
import OSLog

/// What to ask Claude: one user turn, optionally with a screenshot.
struct MessageRequest {
    var model: String
    var effort: Effort
    var systemPrompt: String
    var text: String
    /// PNG data of a pasted screenshot, sent before the text.
    var imagePNG: Data?
    /// Ignored for models without fast mode (see `AnthropicClient.fastModeModels`).
    var fastMode = false
    var maxTokens = 16_000
}

/// Calls the Anthropic Messages API directly with streaming. Swift has no official SDK, so this is raw HTTP.
struct AnthropicClient {
    // A literal that is always a valid URL.
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Models that accept the server-side refusal fallback (`fallbacks: "default"`).
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-fable-5-1"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// Models that support fast mode (research preview, Claude API only): same model, faster output, 2x price.
    static let fastModeModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"]
    static let fastModeBeta = "fast-mode-2026-02-01"

    var session: URLSession = .shared

    /// Streams the response as `StreamEvent`s. Cancelling the consuming task cancels the request.
    func stream(_ request: MessageRequest, apiKey: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let start = ContinuousClock.now
                var lineCount = 0
                var receivedCharacters = 0
                do {
                    let urlRequest = try Self.urlRequest(for: request, apiKey: apiKey)
                    Self.logRequest(request, urlRequest: urlRequest)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    let httpResponse = response as? HTTPURLResponse
                    let status = httpResponse?.statusCode ?? 0
                    let requestID = httpResponse?.value(forHTTPHeaderField: "request-id") ?? "none"
                    Logger.api.info(
                        "Response: HTTP \(status), request-id \(requestID, privacy: .public), headers after \(ContinuousClock.now - start, privacy: .public)"
                    )
                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        Logger.api.error("HTTP \(status) body: \(String(decoding: body, as: UTF8.self), privacy: .public)")
                        throw ClaudeError.fromResponse(status: status, body: body)
                    }
                    for try await line in bytes.lines {
                        lineCount += 1
                        Logger.api.debug("SSE: \(line, privacy: .private)")
                        for event in try SSEParser.events(fromLine: line) {
                            if case let .text(chunk) = event {
                                receivedCharacters += chunk.count
                            }
                            continuation.yield(event)
                        }
                    }
                    Logger.api.info(
                        "Stream finished in \(ContinuousClock.now - start, privacy: .public): \(lineCount) SSE lines, \(receivedCharacters) characters"
                    )
                    continuation.finish()
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        Logger.api.info("Request cancelled after \(ContinuousClock.now - start, privacy: .public)")
                    } else {
                        Logger.api.error(
                            "Request failed after \(ContinuousClock.now - start, privacy: .public): \(error.localizedDescription, privacy: .public) (\(String(describing: error), privacy: .public))"
                        )
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Logs what is being sent, without the API key or the image data.
    private static func logRequest(_ request: MessageRequest, urlRequest: URLRequest) {
        let betas = urlRequest.value(forHTTPHeaderField: "anthropic-beta") ?? "none"
        Logger.api.info(
            """
            Request: model \(request.model, privacy: .public), effort \(request.effort.rawValue, privacy: .public), \
            max_tokens \(request.maxTokens), fast mode \(request.fastMode), betas \(betas, privacy: .public), \
            input \(request.text.count) characters, system prompt \(request.systemPrompt.count) characters, \
            image \(request.imagePNG?.count ?? 0) bytes
            """
        )
        Logger.api.debug("Input: \(request.text, privacy: .private)")
        Logger.api.debug("System prompt: \(request.systemPrompt, privacy: .private)")
    }

    /// Builds the HTTP request. Separate from `stream` so tests can inspect it.
    static func urlRequest(for request: MessageRequest, apiKey: String) throws -> URLRequest {
        var content: [[String: Any]] = []
        if let imagePNG = request.imagePNG {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/png", "data": imagePNG.base64EncodedString()],
            ])
        }
        content.append(["type": "text", "text": request.text])

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "stream": true,
            "messages": [["role": "user", "content": content]],
        ]
        if !request.systemPrompt.isEmpty {
            body["system"] = request.systemPrompt
        }
        // Thinking is left at the model's default (adaptive on current models); effort is the only knob.
        if request.effort != .modelDefault {
            body["output_config"] = ["effort": request.effort.rawValue]
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        var betas: [String] = []
        // On a safety-classifier refusal, let the API retry on Anthropic's recommended model for that category.
        if fallbackModels.contains(request.model) {
            body["fallbacks"] = "default"
            betas.append(fallbackBeta)
        }
        if request.fastMode && fastModeModels.contains(request.model) {
            body["speed"] = "fast"
            betas.append(fastModeBeta)
        }
        if !betas.isEmpty {
            urlRequest.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}
