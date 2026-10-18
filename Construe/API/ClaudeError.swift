import Foundation

enum ClaudeError: LocalizedError, Equatable {
    case missingAPIKey
    /// A non-200 response. `type` and `message` come from the API's error body when present.
    case http(status: Int, type: String?, message: String?)
    /// An `error` event received mid-stream (e.g. `overloaded_error`).
    case stream(type: String, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add your Anthropic API key in Settings."
        case .http(401, _, _):
            "The API key was rejected. Check it in Settings."
        case .http(429, _, _):
            "Rate limited. Try again in a moment."
        case .http(529, _, _), .stream("overloaded_error", _):
            "Claude is overloaded right now. Try again in a moment."
        case let .http(status, _, message):
            message.map { "Error \(status): \($0)" } ?? "Request failed with HTTP \(status)."
        case let .stream(_, message):
            message
        }
    }

    /// Builds the error for a non-200 response from its status code and body
    /// (`{"type":"error","error":{"type":…,"message":…}}`).
    static func fromResponse(status: Int, body: Data) -> ClaudeError {
        struct Body: Decodable {
            struct Detail: Decodable {
                let type: String
                let message: String
            }
            let error: Detail
        }
        let detail = try? JSONDecoder().decode(Body.self, from: body).error
        return .http(status: status, type: detail?.type, message: detail?.message)
    }
}
