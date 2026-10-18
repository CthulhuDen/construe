import Foundation
import Testing
@testable import Construe

@MainActor
struct AppSettingsTests {
    /// A fresh, empty defaults suite per test, so tests don't touch the real preferences.
    private let defaults: UserDefaults

    init() throws {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func defaultsWhenNothingIsStored() {
        let settings = AppSettings(defaults: defaults)

        #expect(settings.model == "claude-opus-5-5")
        #expect(settings.effort == .medium)
        #expect(settings.systemPrompt == AppSettings.defaultSystemPrompt)
        #expect(settings.projectID.isEmpty)
        #expect(settings.handoffPreamble == AppSettings.defaultHandoffPreamble)
        #expect(settings.sendImage)
        #expect(settings.ocrLanguage == nil)
    }

    @Test func changesPersistAcrossInstances() {
        let settings = AppSettings(defaults: defaults)
        settings.model = "claude-haiku-4-5"
        settings.effort = .modelDefault
        settings.systemPrompt = "Custom prompt"
        settings.projectID = "project-123"
        settings.handoffPreamble = "Custom preamble"
        settings.sendImage = false
        settings.ocrLanguage = "es"

        let reloaded = AppSettings(defaults: defaults)

        #expect(reloaded.model == "claude-haiku-4-5")
        #expect(reloaded.effort == .modelDefault)
        #expect(reloaded.systemPrompt == "Custom prompt")
        #expect(reloaded.projectID == "project-123")
        #expect(reloaded.handoffPreamble == "Custom preamble")
        #expect(reloaded.sendImage == false)
        #expect(reloaded.ocrLanguage == "es")
    }

    @Test func ocrLanguageCanBeResetToAutomatic() {
        let settings = AppSettings(defaults: defaults)
        settings.ocrLanguage = "es"
        settings.ocrLanguage = nil

        #expect(AppSettings(defaults: defaults).ocrLanguage == nil)
    }

    @Test func unknownStoredEffortFallsBackToDefault() {
        defaults.set("extreme", forKey: "effort")

        #expect(AppSettings(defaults: defaults).effort == .medium)
    }
}
