import SwiftUI

@main
struct ConstrueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("Open Construe") {
                appDelegate.panelController.show(catchingAudio: true)
            }
            Button(appDelegate.listener.isListening ? "Stop Listening" : "Start Listening") {
                appDelegate.panelController.toggleListening()
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
