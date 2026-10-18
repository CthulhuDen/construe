import Foundation

/// An event from a streamed Messages API response that the app cares about.
enum StreamEvent: Equatable {
    /// A chunk of response text.
    case text(String)
    /// The speed the API reports in `usage.speed` ("fast" or "standard").
    case speed(String)
    /// The model finished; `reason` is the API's `stop_reason` (e.g. "end_turn", "max_tokens", "refusal").
    case stop(reason: String?)
}

/// Turns server-sent event lines from the Messages API into `StreamEvent`s.
///
/// Every Anthropic SSE `data:` line is a self-contained JSON object whose `type` field names the event,
/// so the parser works line by line and ignores `event:` lines and blank separators.
enum SSEParser {
    private struct Payload: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case stopReason = "stop_reason"
            }
        }

        struct Usage: Decodable {
            let speed: String?
        }

        struct Message: Decodable {
            let usage: Usage?
        }

        struct ErrorBody: Decodable {
            let type: String
            let message: String
        }

        let type: String
        let delta: Delta?
        /// Present on `message_delta`.
        let usage: Usage?
        /// Present on `message_start`.
        let message: Message?
        let error: ErrorBody?
    }

    /// Returns the events for one SSE line; empty for lines that carry nothing relevant
    /// (`event:` lines, pings, block start/stop markers, thinking deltas).
    /// Throws `ClaudeError.stream` for an `error` event.
    static func events(fromLine line: String) throws -> [StreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else { return [] }

        switch payload.type {
        case "message_start":
            return payload.message?.usage?.speed.map { [.speed($0)] } ?? []
        case "content_block_delta":
            guard payload.delta?.type == "text_delta", let text = payload.delta?.text else { return [] }
            return [.text(text)]
        case "message_delta":
            var events: [StreamEvent] = []
            if let speed = payload.usage?.speed {
                events.append(.speed(speed))
            }
            events.append(.stop(reason: payload.delta?.stopReason))
            return events
        case "error":
            throw ClaudeError.stream(
                type: payload.error?.type ?? "error",
                message: payload.error?.message ?? "Unknown streaming error"
            )
        default:
            return []
        }
    }
}
