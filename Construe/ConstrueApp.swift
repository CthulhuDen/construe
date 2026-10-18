import SwiftUI

@main
struct ConstrueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Construe", systemImage: "character.bubble") {
            Button("Open Construe") {
                appDelegate.panelController.show()
            }
            Button("Settings…") {
                appDelegate.settingsController.show()
            }
            .keyboardShortcut(",")
            Divider()
            Button("Quit Construe") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
