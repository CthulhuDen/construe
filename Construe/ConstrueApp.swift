import SwiftUI

@main
struct ConstrueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `isInserted` keeps the app running when the user hides the item in System Settings; without
        // it SwiftUI quits the app. Constant, so the item comes back when the user allows it again.
        MenuBarExtra(isInserted: .constant(true)) {
            Button("Open Construe") {
                appDelegate.panelController.show(catchingAudio: true)
            }
            Button(appDelegate.listener.isListening ? "Stop Listening" : "Start Listening") {
                appDelegate.panelController.toggleListening()
            }
            // No ⌘, here: a key press in this menu doesn't let Construe activate, so Settings would open
            // behind the frontmost app. The panel handles ⌘, instead (see `PanelController.show()`).
            Button("Settings…") {
                appDelegate.settingsController.show()
            }
            Divider()
            Button("Quit Construe") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarIcon(listener: appDelegate.listener)
        }
    }
}

/// The menu-bar icon, which changes while listening. A view of its own, so reading
/// `isListening` in its body is tracked by Observation.
private struct MenuBarIcon: View {
    var listener: AudioListener

    var body: some View {
        Label("Construe", systemImage: listener.isListening ? "ear.and.waveform" : "character.bubble")
    }
}
