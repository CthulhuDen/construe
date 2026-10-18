import AppKit
import SwiftUI

/// Owns the quick panel: showing, hiding and positioning it.
final class PanelController {
    static let panelWidth: CGFloat = 640

    private lazy var panel: QuickPanel = {
        let panel = QuickPanel()
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onResignKey = { [weak self] in self?.hide() }
        return panel
    }()

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        // A fresh hosting controller per show gives an empty input every time.
        let hostingController = NSHostingController(rootView: QuickView())
        hostingController.sizingOptions = [.preferredContentSize]
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

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentViewController = nil
    }
}
