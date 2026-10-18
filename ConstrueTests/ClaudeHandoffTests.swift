import Foundation
import Testing
@testable import Construe

@MainActor
struct ClaudeHandoffTests {
    private func queryItems(_ url: URL?) throws -> [String: String] {
        let url = try #require(url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "claude.ai")
        #expect(components.path == "/new")
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func includesProjectWhenSet() throws {
        let items = try queryItems(ClaudeHandoff.url(projectID: "00000000-test-project", text: "hola"))
        #expect(items == ["project": "00000000-test-project", "q": "hola"])
    }

    @Test(arguments: ["", "   "])
    func fallsBackToPlainNewChatWithoutProject(projectID: String) throws {
        let items = try queryItems(ClaudeHandoff.url(projectID: projectID, text: "hola"))
        #expect(items == ["q": "hola"])
    }

    @Test func specialCharactersSurviveTheRoundTrip() throws {
        let text = "¿Qué tal? a+b=c & d#e / [link](https://x.es/?a=1&b=2) ñ\n---\n- bullet"
        let url = try #require(ClaudeHandoff.url(projectID: "p", text: text))
        #expect(!url.absoluteString.contains("+"))
        #expect(!url.absoluteString.contains("#"))
        #expect(try queryItems(url)["q"] == text)
    }

    @Test func fillsPhraseAndReplyPlaceholders() {
        let text = ClaudeHandoff.text(template: "Intro\n\n{{phrase}}\n---\n{{reply}}\n---\n\n", phrase: " Hola ", reply: "Hello\n")
        #expect(text == "Intro\n\nHola\n---\nHello\n---\n\n")
    }

    @Test func defaultTemplateEndsWithRoomForAFollowUp() {
        let text = ClaudeHandoff.text(template: AppSettings.defaultHandoffTemplate, phrase: "Hola", reply: "Hello")
        #expect(text.hasSuffix("Hello\n\n---\n\n"))
        #expect(!text.contains("Construe"))
        #expect(!text.contains("{{"))
    }

    @Test func longReplyIsTrimmedButTemplateTailSurvives() {
        let reply = String(repeating: "palabra ", count: 5_000)
        let text = ClaudeHandoff.text(template: "{{phrase}}\n---\n{{reply}}\n---\n\n", phrase: "Hola", reply: reply)
        #expect(text.count <= ClaudeHandoff.maxTextLength)
        #expect(text.hasPrefix("Hola\n---\npalabra"))
        #expect(text.hasSuffix("…\n---\n\n"))
    }

    @Test func longPhraseIsTrimmedToo() {
        let phrase = String(repeating: "x", count: 20_000)
        let text = ClaudeHandoff.text(template: "{{phrase}}\n{{reply}}", phrase: phrase, reply: "Hello")
        #expect(text.count == ClaudeHandoff.maxTextLength)
    }

    @Test func templateWithoutPlaceholdersIsUsedAsIs() {
        #expect(ClaudeHandoff.text(template: "Just this", phrase: "Hola", reply: "Hello") == "Just this")
    }
}
