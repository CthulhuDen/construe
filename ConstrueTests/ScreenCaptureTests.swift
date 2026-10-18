import CoreGraphics
import Foundation
import Testing
@testable import Construe

@MainActor
struct ScreenCapturerTests {
    @Test func mainScreenFlipsToTopLeftOrigin() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let rect = CGRect(x: 100, y: 50, width: 600, height: 80)
        #expect(ScreenCapturer.displayLocalRect(rect, screenFrame: screen) == CGRect(x: 100, y: 852, width: 600, height: 80))
    }

    @Test func secondaryScreenLeftOfAndAboveMain() {
        // AppKit places screens left of the main one at negative x, and above it at y beyond its height.
        let screen = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        let rect = CGRect(x: -1820, y: 1032, width: 800, height: 100)
        #expect(ScreenCapturer.displayLocalRect(rect, screenFrame: screen) == CGRect(x: 100, y: 930, width: 800, height: 100))
    }
}

@MainActor
struct TranslationSessionCaptureTests {
    @Test func imageNoticeIsShownAndRemoved() throws {
        let defaults = try #require(UserDefaults(suiteName: "SessionCaptureTests-\(UUID().uuidString)"))
        let session = TranslationSession(settings: AppSettings(defaults: defaults), apiKey: { nil })
        session.showImageNotice("No region yet.")
        #expect(session.imageNotice == "No region yet.")
        session.removeImage()
        #expect(session.imageNotice == nil)
    }
}
