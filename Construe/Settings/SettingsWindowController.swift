import AppKit
import SwiftUI

/// Shows the Settings window on the current Space (including over fullscreen apps) and gives it focus.
///
/// SwiftUI's `Settings` scene can't be configured this way, and a menu-bar-only app isn't activated
/// when it opens a window, so the window is managed here instead. A toolbar-style tab view controller
/// gives the standard macOS settings look: icon tabs in the toolbar, the window title following the
/// selected tab, and the window resizing to each tab's content.
final class SettingsWindowController {
    private let settings: AppSettings
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab(GeneralSettingsView(), label: "General", symbol: "gearshape"))
        tabs.addTabViewItem(tab(ClaudeSettingsView(settings: settings), label: "Claude", symbol: "sparkles"))
        tabs.addTabViewItem(tab(PromptSettingsView(settings: settings), label: "Prompt", symbol: "text.bubble"))
        tabs.addTabViewItem(tab(HandoffSettingsView(settings: settings), label: "Handoff", symbol: "arrow.up.forward.app"))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.center()

        // Construe has no other regular windows, so hand focus back to the previous app on close.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { NSApp.hide(nil) }
        }
        return window
    }

    private func tab(_ view: some View, label: String, symbol: String) -> NSTabViewItem {
        let hostingController = NSHostingController(rootView: view)
        // Report the SwiftUI content size so the tab view controller sizes the window to each tab.
        hostingController.sizingOptions = [.preferredContentSize]
        // The tab view controller copies the selected tab's title into the window title.
        hostingController.title = label
        let item = NSTabViewItem(viewController: hostingController)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}
