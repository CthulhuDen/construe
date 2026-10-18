import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Construe

/// Renders test images in code, so no image fixtures need to live in the repository.
enum TestImages {
    struct RenderError: Error {}

    /// White text on a dark background, like a subtitle.
    static func text(_ string: String, width: Int = 1400, height: Int = 220, pointSize: CGFloat = 72) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RenderError() }
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (string as NSString).draw(
            at: NSPoint(x: 40, y: CGFloat(height) / 2 - pointSize / 2),
            withAttributes: [.font: NSFont.systemFont(ofSize: pointSize), .foregroundColor: NSColor.white]
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { throw RenderError() }
        return image
    }

    static func blank(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RenderError() }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw RenderError() }
        return image
    }
}

@MainActor
struct TextRecognizerTests {
    @Test(arguments: [nil, "es"] as [String?])
    func recognizesSpanishSubtitle(language: String?) async throws {
        let image = try TestImages.text("¿Dónde está la biblioteca?")
        let text = try await TextRecognizer.recognizeText(in: image, language: language)
        #expect(text.lowercased().contains("biblioteca"))
        #expect(text.contains("Dónde") || text.contains("Donde"))
    }

    @Test func blankImageHasNoText() async throws {
        let text = try await TextRecognizer.recognizeText(in: try TestImages.blank(width: 400, height: 200), language: nil)
        #expect(text.isEmpty)
    }
}

@MainActor
struct ImageAttachmentTests {
    @Test func largeImageIsScaledToMaxLongEdge() throws {
        let scaled = try #require(ImageAttachment.downscaled(try TestImages.blank(width: 3136, height: 1000)))
        #expect(scaled.width == 1568)
        #expect(scaled.height == 500)
    }

    @Test func smallImageIsUnchanged() throws {
        let image = try TestImages.blank(width: 800, height: 600)
        let scaled = try #require(ImageAttachment.downscaled(image))
        #expect(scaled.width == 800 && scaled.height == 600)
    }

    @Test func pngDataDecodes() throws {
        let data = try #require(ImageAttachment.pngData(for: try TestImages.blank(width: 2000, height: 400)))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 1568)
    }
}

@MainActor
struct TranslationSessionImageTests {
    private func makeSession() throws -> TranslationSession {
        let defaults = try #require(UserDefaults(suiteName: "SessionImageTests-\(UUID().uuidString)"))
        return TranslationSession(settings: AppSettings(defaults: defaults), apiKey: { nil })
    }

    @Test func recognizedTextFillsEmptyInput() async throws {
        let session = try makeSession()
        await session.attachImage(try TestImages.text("Hola amigo"))
        #expect(session.input.lowercased().contains("hola"))
        #expect(session.imagePNG != nil)
        #expect(session.isReadingImage == false)
    }

    @Test func recognizedTextIsAppendedToExistingInput() async throws {
        let session = try makeSession()
        session.input = "Context:"
        await session.attachImage(try TestImages.text("Hola"))
        #expect(session.input.hasPrefix("Context: "))
    }

    @Test func blankScreenshotShowsNotice() async throws {
        let session = try makeSession()
        await session.attachImage(try TestImages.blank(width: 400, height: 200))
        #expect(session.input.isEmpty)
        #expect(session.imageNotice != nil)
    }

    @Test func clearInputRemovesTextAndImage() async throws {
        let session = try makeSession()
        await session.attachImage(try TestImages.text("Hola"))
        session.clearInput()
        #expect(session.input.isEmpty)
        #expect(session.imagePNG == nil)
        #expect(session.imageNotice == nil)
    }
}

/// Exercises the input's Paste through AppKit's own validation, with a private pasteboard
/// so the user's clipboard is never touched.
@MainActor
struct PasteAwareTextViewTests {
    private func makeTextView(pasting write: (NSPasteboard) -> Void) -> (PasteAwareTextView, NSPasteboard) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ConstrueTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        write(pasteboard)
        let textView = PasteAwareTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.pasteboard = pasteboard
        return (textView, pasteboard)
    }

    private func pasteMenuItem() -> NSMenuItem {
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    }

    @Test func pasteIsEnabledForScreenshot() throws {
        let image = NSImage(cgImage: try TestImages.blank(width: 100, height: 50), size: .zero)
        let (textView, pasteboard) = makeTextView { $0.writeObjects([image]) }
        defer { pasteboard.releaseGlobally() }

        #expect(textView.validateUserInterfaceItem(pasteMenuItem()))
    }

    @Test func pastingScreenshotHandsOverImage() throws {
        let image = NSImage(cgImage: try TestImages.blank(width: 100, height: 50), size: .zero)
        let (textView, pasteboard) = makeTextView { $0.writeObjects([image]) }
        defer { pasteboard.releaseGlobally() }
        var received: CGImage?
        textView.onPasteImage = { received = $0 }

        textView.paste(nil)

        #expect(received?.width == 100)
        #expect(textView.string.isEmpty)
    }

    @Test func textWinsOverImage() throws {
        let image = NSImage(cgImage: try TestImages.blank(width: 100, height: 50), size: .zero)
        let (textView, pasteboard) = makeTextView {
            $0.writeObjects(["hola" as NSString, image])
        }
        defer { pasteboard.releaseGlobally() }
        var received: CGImage?
        textView.onPasteImage = { received = $0 }

        textView.paste(nil)

        #expect(received == nil)
    }
}
