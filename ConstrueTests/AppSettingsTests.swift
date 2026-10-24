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
        #expect(settings.handoffTemplate == AppSettings.defaultHandoffTemplate)
        #expect(settings.sendImage)
        #expect(settings.ocrLanguage == nil)
        #expect(settings.fastMode == false)
        #expect(settings.speechLocale == nil)
        #expect(settings.listeningBufferSeconds == 15)
        #expect(settings.listeningAutoStopMinutes == 30)
    }

    @Test func changesPersistAcrossInstances() {
        let settings = AppSettings(defaults: defaults)
        settings.model = "claude-haiku-4-5"
        settings.effort = .modelDefault
        settings.systemPrompt = "Custom prompt"
        settings.projectID = "project-123"
        settings.handoffTemplate = "Custom {{reply}}"
        settings.sendImage = false
        settings.ocrLanguage = "es"
        settings.fastMode = true
        settings.speechLocale = "es-ES"
        settings.listeningBufferSeconds = 30
        settings.listeningAutoStopMinutes = 0

        let reloaded = AppSettings(defaults: defaults)

        #expect(reloaded.model == "claude-haiku-4-5")
        #expect(reloaded.effort == .modelDefault)
        #expect(reloaded.systemPrompt == "Custom prompt")
        #expect(reloaded.projectID == "project-123")
        #expect(reloaded.handoffTemplate == "Custom {{reply}}")
        #expect(reloaded.sendImage == false)
        #expect(reloaded.ocrLanguage == "es")
        #expect(reloaded.fastMode)
        #expect(reloaded.speechLocale == "es-ES")
        #expect(reloaded.listeningBufferSeconds == 30)
        #expect(reloaded.listeningAutoStopMinutes == 0)
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
