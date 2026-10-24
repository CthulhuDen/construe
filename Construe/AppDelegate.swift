import AppKit
import KeyboardShortcuts
import OSLog

extension KeyboardShortcuts.Name {
    /// Global shortcut that shows or hides the quick panel.
    static let togglePanel = Self("togglePanel", initial: .init(.space, modifiers: [.control, .option]))
    /// In the panel only: drag out a screen region to read text from.
    static let grabRegion = Self("grabRegion", initial: .init(.x, modifiers: [.control, .option]))
    /// In the panel only: capture the last region again.
    static let regrabRegion = Self("regrabRegion", initial: .init(.c, modifiers: [.control, .option]))
    /// Global shortcut that captures the last region again and opens the panel. Shares its default
    /// with `regrabRegion`, so the same key works everywhere.
    static let globalRegrab = Self("globalRegrab", initial: .init(.c, modifiers: [.control, .option]))
    /// Global shortcut that starts or stops listening to system audio.
    static let toggleListening = Self("toggleListening", initial: .init(.l, modifiers: [.control, .option]))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    lazy var settingsController = SettingsWindowController(settings: settings)
    lazy var listener = AudioListener(settings: settings)
    lazy var panelController = PanelController(settings: settings, listener: listener) { [weak self] in
        self?.settingsController.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Logger.panel.info("Construe \(version, privacy: .public) launched")
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.panelController.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .globalRegrab) { [weak self] in
            self?.panelController.regrabRegion()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleListening) { [weak self] in
            self?.panelController.toggleListening()
        }
    }
}
