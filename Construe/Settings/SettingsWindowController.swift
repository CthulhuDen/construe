import AppKit
import SwiftUI

/// Shows the Settings window as a regular window and gives it focus.
///
/// A menu-bar-only app isn't activated when it opens a window, so the window is managed here instead
/// of by SwiftUI's `Settings` scene. A toolbar-style tab view controller
/// gives the standard macOS settings look: icon tabs in the toolbar, the window title following the
/// selected tab, and the window resizing to each tab's content.
final class SettingsWindowController {
    private let settings: AppSettings
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    /// Set while `show()` waits for the system to leave a fullscreen app's Space.
    private var pendingShow: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        // Activate now, synchronously: the system only honors a request made while the app handles the
        // user's click or key press. Later ones are refused, even with `ignoringOtherApps`.
        NSApp.activate()
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard pendingShow == nil else { return }
        // A regular app while Settings is open: the window opens on the desktop like any other app's,
        // with a Dock icon, ⌘Tab and Mission Control. Back to menu-bar-only on close.
        NSApp.setActivationPolicy(.regular)
        pendingShow = Task {
            // Once Construe is active as a regular app, the system leaves a fullscreen app's Space for the
            // desktop. A window ordered in before that lands on the fullscreen Space instead. Without a
            // fullscreen app there's no Space change, so stop waiting after a short while.
            let spaceChanges = NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.activeSpaceDidChangeNotification
            )
            let waitForSpaceChange = Task { for await _ in spaceChanges { break } }
            let timeout = Task {
                try? await Task.sleep(for: .milliseconds(500))
                waitForSpaceChange.cancel()
            }
            await waitForSpaceChange.value
            timeout.cancel()
            pendingShow = nil

            // A new window each time: a reused one returns to the Space it was last shown on.
            let window = makeWindow()
            self.window = window
            window.makeKeyAndOrderFront(nil)
            // Don't start with the first shortcut recorder focused: it would record the next key press.
            window.makeFirstResponder(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab(GeneralSettingsView(), label: "General", symbol: "gearshape"))
        tabs.addTabViewItem(tab(ListeningSettingsView(settings: settings), label: "Listening", symbol: "ear"))
        tabs.addTabViewItem(tab(ClaudeSettingsView(settings: settings), label: "Claude", symbol: "sparkles"))
        tabs.addTabViewItem(tab(PromptSettingsView(settings: settings), label: "Prompt", symbol: "text.bubble"))
        tabs.addTabViewItem(tab(HandoffSettingsView(settings: settings), label: "Handoff", symbol: "arrow.up.forward.app"))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.center()

        // Construe has no other regular windows, so hand focus back to the previous app on close.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let closeObserver = self?.closeObserver {
                    NotificationCenter.default.removeObserver(closeObserver)
                }
                self?.window = nil
                NSApp.hide(nil)
                NSApp.setActivationPolicy(.accessory)
            }
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
