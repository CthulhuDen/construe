import Testing
@testable import Construe

@MainActor
struct SSEParserTests {
    @Test func parsesTextDelta() throws {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hola, ¿qué tal?"}}"#
        #expect(try SSEParser.events(fromLine: line) == [.text("Hola, ¿qué tal?")])
    }

    @Test func parsesStopReason() throws {
        let line = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#
        #expect(try SSEParser.events(fromLine: line) == [.stop(reason: "end_turn")])
    }

    @Test(arguments: [
        "event: content_block_delta",
        "",
        #"data: {"type":"ping"}"#,
        #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5"}}"#,
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"…"}}"#,
        #"data: {"type":"content_block_stop","index":0}"#,
        #"data: {"type":"message_stop"}"#,
        "data: not json",
    ])
    func ignoresIrrelevantLines(line: String) throws {
        #expect(try SSEParser.events(fromLine: line).isEmpty)
    }

    @Test func reportsSpeedFromMessageStart() throws {
        let line = #"data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":10,"speed":"fast"}}}"#
        #expect(try SSEParser.events(fromLine: line) == [.speed("fast")])
    }

    @Test func reportsSpeedAndStopFromMessageDelta() throws {
        let line = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5,"speed":"standard"}}"#
        #expect(try SSEParser.events(fromLine: line) == [.speed("standard"), .stop(reason: "end_turn")])
    }

    @Test func throwsOnErrorEvent() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(throws: ClaudeError.stream(type: "overloaded_error", message: "Overloaded")) {
            try SSEParser.events(fromLine: line)
        }
    }

    @Test func toleratesMissingSpaceAfterDataPrefix() throws {
        let line = #"data:{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}"#
        #expect(try SSEParser.events(fromLine: line) == [.text("x")])
    }
}
