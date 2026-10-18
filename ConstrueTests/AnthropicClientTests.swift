import Foundation
import Testing
@testable import Construe

@MainActor
struct AnthropicClientRequestTests {
    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeRequest(model: String = "claude-opus-5-5", effort: Effort = .medium, image: Data? = nil) -> MessageRequest {
        MessageRequest(model: model, effort: effort, systemPrompt: "Be brief.", text: "¿Qué tal?", imagePNG: image)
    }

    @Test func headersAndEndpoint() throws {
        let request = try AnthropicClient.urlRequest(for: makeRequest(), apiKey: "sk-ant-test")

        #expect(request.url == AnthropicClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test func textOnlyBody() throws {
        let body = try body(of: AnthropicClient.urlRequest(for: makeRequest(), apiKey: "k"))

        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["max_tokens"] as? Int == 16_000)
        #expect(body["stream"] as? Bool == true)
        #expect(body["system"] as? String == "Be brief.")
        #expect(body["thinking"] == nil)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "¿Qué tal?")
    }

    @Test func imageGoesBeforeText() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let body = try body(of: AnthropicClient.urlRequest(for: makeRequest(image: png), apiKey: "k"))

        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == png.base64EncodedString())
    }

    @Test func effortIsSentUnlessModelDefault() throws {
        let low = try body(of: AnthropicClient.urlRequest(for: makeRequest(effort: .low), apiKey: "k"))
        #expect((low["output_config"] as? [String: Any])?["effort"] as? String == "low")

        let modelDefault = try body(of: AnthropicClient.urlRequest(for: makeRequest(effort: .modelDefault), apiKey: "k"))
        #expect(modelDefault["output_config"] == nil)
    }

    @Test func emptySystemPromptIsOmitted() throws {
        var request = makeRequest()
        request.systemPrompt = ""
        #expect(try body(of: AnthropicClient.urlRequest(for: request, apiKey: "k"))["system"] == nil)
    }

    @Test(arguments: ["claude-opus-5-5", "claude-sonnet-5-5"])
    func fallbacksForSupportedModels(model: String) throws {
        let request = try AnthropicClient.urlRequest(for: makeRequest(model: model), apiKey: "k")
        #expect(try body(of: request)["fallbacks"] as? String == "default")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
    }

    @Test func fastModeAddsSpeedAndBothBetas() throws {
        var request = makeRequest(model: "claude-opus-5-5")
        request.fastMode = true
        let urlRequest = try AnthropicClient.urlRequest(for: request, apiKey: "k")

        #expect(try body(of: urlRequest)["speed"] as? String == "fast")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta")
            == "server-side-fallback-2026-07-01,fast-mode-2026-02-01")
    }

    @Test(arguments: ["claude-sonnet-5-5", "claude-haiku-4-5"])
    func fastModeIgnoredForUnsupportedModels(model: String) throws {
        var request = makeRequest(model: model)
        request.fastMode = true
        let urlRequest = try AnthropicClient.urlRequest(for: request, apiKey: "k")

        #expect(try body(of: urlRequest)["speed"] == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta")?.contains("fast-mode") != true)
    }

    @Test func fastModeOffByDefault() throws {
        let urlRequest = try AnthropicClient.urlRequest(for: makeRequest(), apiKey: "k")
        #expect(try body(of: urlRequest)["speed"] == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
    }

    @Test func noFallbacksForOtherModels() throws {
        let request = try AnthropicClient.urlRequest(for: makeRequest(model: "claude-haiku-4-5"), apiKey: "k")
        #expect(try body(of: request)["fallbacks"] == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }
}

/// Serves a canned HTTP response to any request made through a session that registers it.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    /// Body of the last request served, for inspecting what the client sent.
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves the body into a stream before it reaches a URLProtocol.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastRequestBody = data
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Runs the full client against `StubURLProtocol`. Serialized because the stub is shared state.
@Suite(.serialized)
@MainActor
struct AnthropicClientStreamTests {
    private let client: AnthropicClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AnthropicClient(session: URLSession(configuration: configuration))
    }()

    private let request = MessageRequest(model: "claude-opus-5-5", effort: .low, systemPrompt: "", text: "hola")

    private func collect() async throws -> [StreamEvent] {
        var events: [StreamEvent] = []
        for try await event in client.stream(request, apiKey: "k") {
            events.append(event)
        }
        return events
    }

    @Test func streamsTextAndStop() async throws {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("""
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_1"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}

            event: ping
            data: {"type":"ping"}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

            event: message_stop
            data: {"type":"message_stop"}

            """.utf8)

        #expect(try await collect() == [.text("Hel"), .text("lo"), .stop(reason: "end_turn")])
    }

    @Test func streamErrorEventThrows() async {
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("""
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}
            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

            """.utf8)

        await #expect(throws: ClaudeError.stream(type: "overloaded_error", message: "Overloaded")) {
            try await collect()
        }
    }

    @Test(arguments: [
        (401, "authentication_error", "invalid x-api-key"),
        (429, "rate_limit_error", "Too many requests"),
        (529, "overloaded_error", "Overloaded"),
        (400, "invalid_request_error", "model: not found"),
    ])
    func httpErrorsCarryStatusAndDetail(status: Int, type: String, message: String) async {
        StubURLProtocol.status = status
        StubURLProtocol.body = Data(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#.utf8)

        await #expect(throws: ClaudeError.http(status: status, type: type, message: message)) {
            try await collect()
        }
    }

    // MARK: TranslationSession with the stubbed client (here because the stub is shared, serialized state)

    private func finishedSession(
        fastMode: Bool, model: String = "claude-opus-5-5", sendImage: Bool = true,
        prepare: (TranslationSession) async throws -> Void = { _ in }
    ) async throws -> TranslationSession {
        let suiteName = "SessionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.model = model
        settings.fastMode = fastMode
        settings.sendImage = sendImage

        let session = TranslationSession(settings: settings, client: client, apiKey: { "k" })
        session.input = "hola"
        try await prepare(session)
        session.send()
        for _ in 0..<500 where session.phase == .streaming {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.phase == .done)
        return session
    }

    private func stubStream(speed: String?) {
        let usage = speed.map { #","usage":{"output_tokens":1,"speed":"\#($0)"}"# } ?? ""
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("""
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}\(usage)}

            """.utf8)
    }

    @Test func fastModeConfirmedShowsNoBanner() async throws {
        stubStream(speed: "fast")
        let session = try await finishedSession(fastMode: true)
        #expect(session.response == "Hello")
        #expect(session.notices.isEmpty)
    }

    @Test(arguments: [nil, "standard"] as [String?])
    func fastModeNotConfirmedShowsBanner(speed: String?) async throws {
        stubStream(speed: speed)
        let session = try await finishedSession(fastMode: true)
        #expect(session.notices.count == 1)
        #expect(session.notices.first?.contains("Fast mode") == true)
    }

    @Test func noBannerWhenFastModeOff() async throws {
        stubStream(speed: "standard")
        #expect(try await finishedSession(fastMode: false).notices.isEmpty)
    }

    @Test func noBannerForModelWithoutFastMode() async throws {
        stubStream(speed: nil)
        #expect(try await finishedSession(fastMode: true, model: "claude-haiku-4-5").notices.isEmpty)
    }

    private func sentContentTypes() throws -> [String] {
        let data = try #require(StubURLProtocol.lastRequestBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        return content.compactMap { $0["type"] as? String }
    }

    @Test(arguments: [true, false])
    func screenshotIsSentOnlyWhenEnabled(sendImage: Bool) async throws {
        stubStream(speed: nil)
        StubURLProtocol.lastRequestBody = nil
        _ = try await finishedSession(fastMode: false, sendImage: sendImage) { session in
            await session.attachImage(try TestImages.text("Hola"))
        }
        #expect(try sentContentTypes() == (sendImage ? ["image", "text"] : ["text"]))
    }

    @Test func handoffUsesTheSentPhraseAfterTheInputIsCleared() async throws {
        stubStream(speed: nil)
        let session = try await finishedSession(fastMode: false)
        session.clearInput()

        let url = try #require(session.handoffURL)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(q?.contains("hola\n\n---\n\nHello\n\n---") == true)
    }

    @Test func noHandoffBeforeAResponse() throws {
        let defaults = try #require(UserDefaults(suiteName: "HandoffTests-\(UUID().uuidString)"))
        #expect(TranslationSession(settings: AppSettings(defaults: defaults), apiKey: { nil }).handoffURL == nil)
    }

    @Test func httpErrorWithoutJSONBody() async {
        StubURLProtocol.status = 502
        StubURLProtocol.body = Data("Bad Gateway".utf8)

        await #expect(throws: ClaudeError.http(status: 502, type: nil, message: nil)) {
            try await collect()
        }
    }
}

@MainActor
struct ClaudeErrorTests {
    @Test func userFacingMessages() {
        #expect(ClaudeError.http(status: 401, type: nil, message: nil).localizedDescription.contains("Settings"))
        #expect(ClaudeError.http(status: 529, type: nil, message: nil).localizedDescription.contains("overloaded"))
        #expect(ClaudeError.stream(type: "overloaded_error", message: "x").localizedDescription.contains("overloaded"))
        #expect(ClaudeError.http(status: 400, type: nil, message: "model: not found").localizedDescription
            == "Error 400: model: not found")
    }
}
