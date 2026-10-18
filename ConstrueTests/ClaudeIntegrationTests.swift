import Foundation
import Testing
@testable import Construe

extension Tag {
    /// Tests that call the real Anthropic API. They cost a little money and need a key.
    @Tag static var integration: Self
}

/// The key comes from the `ANTHROPIC_API_KEY` environment variable, which the Integration test plan
/// fills in from the `ANTHROPIC_API_KEY` build setting in `Config/Local.xcconfig`.
private let integrationAPIKey: String? = {
    let value = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    return value?.isEmpty == false ? value : nil
}()

/// Runs only in the Integration test plan, which includes the `integration` tag; the Unit plan excludes it.
/// Without a key the tests fail with a pointer to the setup rather than silently skipping.
@Suite(.tags(.integration))
@MainActor
struct ClaudeIntegrationTests {
    private func requireKey() throws -> String {
        try #require(integrationAPIKey, "Set ANTHROPIC_API_KEY in Config/Local.xcconfig and run the Integration test plan")
    }

    private func run(
        model: String, effort: Effort, fastMode: Bool = false, apiKey: String
    ) async throws -> (text: String, stopReason: String?, speed: String?) {
        let request = MessageRequest(
            model: model,
            effort: effort,
            systemPrompt: "Reply with a single English word and nothing else.",
            text: "Translate to English: hola",
            fastMode: fastMode,
            maxTokens: 2_000
        )
        var text = ""
        var stopReason: String?
        var speed: String?
        for try await event in AnthropicClient().stream(request, apiKey: apiKey) {
            switch event {
            case let .text(chunk): text += chunk
            case let .speed(reported): speed = reported
            case let .stop(reason): stopReason = reason
            }
        }
        return (text, stopReason, speed)
    }

    /// Cheapest model; exercises the request without `effort` or `fallbacks`.
    @Test func haikuStreamsAnAnswer() async throws {
        let result = try await run(model: "claude-haiku-4-5", effort: .modelDefault, apiKey: try requireKey())
        #expect(result.text.lowercased().contains("hello") || result.text.lowercased().contains("hi"))
        #expect(result.stopReason == "end_turn")
    }

    /// The default model; exercises `output_config.effort` and the `fallbacks` beta.
    @Test func opusStreamsAnAnswerWithEffortAndFallbacks() async throws {
        let result = try await run(model: "claude-opus-5-5", effort: .low, apiKey: try requireKey())
        #expect(!result.text.isEmpty)
        #expect(result.stopReason == "end_turn")
    }

    /// Fast mode on the default model; exercises `speed` together with the fallbacks beta in one header.
    @Test func opusFastModeStreamsAnAnswer() async throws {
        let result = try await run(model: "claude-opus-5-5", effort: .low, fastMode: true, apiKey: try requireKey())
        #expect(!result.text.isEmpty)
        #expect(result.stopReason == "end_turn")
        // The app's fast-mode banner relies on the API reporting this.
        #expect(result.speed == "fast")
    }

    @Test func invalidKeyIsRejected() async {
        await #expect {
            try await run(model: "claude-haiku-4-5", effort: .modelDefault, apiKey: "sk-ant-invalid")
        } throws: { error in
            guard case .http(401, _, _) = error as? ClaudeError else { return false }
            return true
        }
    }
}
