import AppKit
import SwiftUI

/// The panel's input: a multi-line AppKit text view, because SwiftUI's `TextField` can't intercept
/// pasted images. Return submits, Shift-Return inserts a newline, Esc closes the panel, and the view
/// grows with its text up to `maxLines`, then scrolls.
struct InputTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont = .preferredFont(forTextStyle: .title2)
    var maxLines = 4
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
        // Turned on by `sizeThatFits` only once the text exceeds `maxLines`.
        scrollView.hasVerticalScroller = false
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
              let layoutManager = textView.layoutManager
        else { return nil }

        let width = proposal.width ?? 400
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let textHeight = Self.textHeight(textView.string, font: font, width: width)
        let maxHeight = lineHeight * CGFloat(maxLines)
        // A legacy scroller ("Show scroll bars: Always") narrows the text, so with auto-hide a
        // momentary overflow would show it, rewrap the text into an extra line and keep it shown.
        // Measured without a scroller, text within `maxLines` fits as is; text beyond it still
        // needs more than `maxLines` once narrowed. Probe widths (see `textHeight`) are skipped.
        if let proposed = proposal.width, proposed > 0, proposed.isFinite {
            nsView.hasVerticalScroller = textHeight > maxHeight
        }
        let height = min(max(textHeight, lineHeight), maxHeight)
        return CGSize(width: width, height: height.rounded(.up))
    }

    /// Height of `string` laid out at `width`, measured with a separate TextKit stack.
    ///
    /// SwiftUI also calls `sizeThatFits` with probe widths (zero, infinity) that it never applies.
    /// Measuring with the visible text container would leave it at the last probed width, which,
    /// if the view's frame then doesn't change, shows the text as one long, clipped line.
    private static func textHeight(_ string: String, font: NSFont, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: string, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height
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
