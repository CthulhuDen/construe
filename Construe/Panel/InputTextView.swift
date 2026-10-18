import AppKit
import SwiftUI

/// The panel's input: a multi-line AppKit text view, because SwiftUI's `TextField` can't intercept
/// pasted images. Return submits, Shift-Return inserts a newline, Esc closes the panel, and the view
/// grows with its text up to `maxLines`, then scrolls.
struct InputTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont = .preferredFont(forTextStyle: .title2)
    var maxLines = 6
    var onSubmit: () -> Void
    var onPasteImage: (CGImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, so the layout manager can be used to measure the text height.
        let textView = PasteAwareTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.font = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.placeholder = placeholder
        textView.onPasteImage = { [weak coordinator = context.coordinator] image in
            coordinator?.parent.onPasteImage(image)
        }
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // The view is created each time the panel opens; focus it once it's in the (key) panel.
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return nil }

        let width = proposal.width ?? 400
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let textHeight = layoutManager.usedRect(for: container).height
        let height = min(max(textHeight, lineHeight), lineHeight * CGFloat(maxLines))
        return CGSize(width: width, height: height.rounded(.up))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InputTextView

        init(parent: InputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.onSubmit()
            }
            return true
        }
    }
}

/// Text view that hands pasted images to `onPasteImage`, pastes text as plain text,
/// passes Esc on to the panel, and draws a placeholder while empty.
final class PasteAwareTextView: NSTextView {
    var placeholder = ""
    var onPasteImage: ((CGImage) -> Void)?
    /// The pasteboard read by Paste; tests substitute a private one.
    var pasteboard = NSPasteboard.general

    /// The image to hand over on Paste. Text wins when both are present (e.g. content copied from a
    /// web page); a screenshot has no text.
    private var pastedImage: CGImage? {
        guard pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // A plain-text view only accepts text, so AppKit would disable Paste (and beep on Cmd-V)
    // for a screenshot. Declaring image types keeps Paste enabled for images.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff]
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), pastedImage != nil {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        if let image = pastedImage {
            onPasteImage?(image)
        } else {
            pasteAsPlainText(sender)
        }
    }

    // NSTextView treats Esc as "complete"; the panel uses it to close instead.
    override func cancelOperation(_ sender: Any?) {
        window?.cancelOperation(sender)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
    }
}
