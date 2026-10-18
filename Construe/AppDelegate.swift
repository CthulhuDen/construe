import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global shortcut that shows or hides the quick panel.
    static let togglePanel = Self("togglePanel", initial: .init(.space, modifiers: [.control, .option]))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let panelController = PanelController()
    lazy var settingsController = SettingsWindowController(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.panelController.toggle()
        }
    }
}
