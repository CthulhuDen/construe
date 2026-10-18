import AppKit
import SwiftUI

/// Owns the quick panel: showing, hiding and positioning it.
final class PanelController {
    static let panelWidth: CGFloat = 640

    private let openSettings: () -> Void
    /// One session for the app's lifetime, so the last reply survives closing the panel
    /// (e.g. to follow a link) and is still there on the next invocation.
    private let session: TranslationSession

    private lazy var panel: QuickPanel = {
        let panel = QuickPanel()
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onResignKey = { [weak self] in self?.hide() }
        return panel
    }()

    init(settings: AppSettings, openSettings: @escaping () -> Void) {
        self.session = TranslationSession(settings: settings)
        self.openSettings = openSettings
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        // Each invocation starts with an empty input but keeps the previous reply.
        session.input = ""
        let rootView = QuickView(
            session: session,
            openSettings: { [weak self] in
                self?.hide()
                self?.openSettings()
            },
            onHeightChange: { [weak self] height in
                // Resize on the next run loop turn, never inside the layout pass that reported the
                // change: resizing the window during layout re-enters layout and can overflow the stack.
                DispatchQueue.main.async { self?.resizePanel(toHeight: height) }
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        // The panel is sized explicitly from `onHeightChange`, not by the hosting controller.
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            // Top edge sits about a fifth of the way down the screen, like Spotlight.
            let top = visibleFrame.maxY - visibleFrame.height * 0.2
            panel.pinnedTop = top
            let size = hostingController.view.fittingSize
            panel.setFrame(
                NSRect(x: visibleFrame.midX - Self.panelWidth / 2, y: top - size.height,
                       width: Self.panelWidth, height: size.height),
                display: false
            )
        }

        // Makes the panel key without activating Construe, so the previous app stays frontmost.
        panel.makeKeyAndOrderFront(nil)
    }

    private func resizePanel(toHeight height: CGFloat) {
        guard panel.isVisible, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.size.height = height
        // `QuickPanel` keeps the top edge fixed, so the panel grows downward.
        panel.setFrame(frame, display: true)
    }

    func hide() {
        guard panel.isVisible else { return }
        // A reply still streaming keeps going in the background and is shown on the next invocation.
        panel.orderOut(nil)
        panel.contentViewController = nil
    }
}
