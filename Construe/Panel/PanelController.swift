import AppKit
import KeyboardShortcuts
import OSLog
import SwiftUI

/// Owns the quick panel: showing, hiding and positioning it.
final class PanelController {
    static let panelWidth: CGFloat = 640

    private let openSettings: () -> Void
    /// One session for the app's lifetime, so the last reply survives closing the panel
    /// (e.g. to follow a link) and is still there on the next invocation.
    private let session: TranslationSession
    private let listener: AudioListener
    /// Lives as long as the controller, so opening and closing the panel never creates or destroys an audio engine.
    private let player = AudioClipPlayer()
    /// The last region grabbed from the screen, for Re-grab. Kept in memory only.
    private var lastRegion: CGRect?

    private lazy var panel: QuickPanel = {
        let panel = QuickPanel()
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onResignKey = { [weak self] in self?.hide() }
        return panel
    }()

    init(settings: AppSettings, listener: AudioListener, openSettings: @escaping () -> Void) {
        self.session = TranslationSession(settings: settings)
        self.listener = listener
        self.openSettings = openSettings
    }

    func toggle() {
        panel.isVisible ? hide() : show(catchingAudio: true)
    }

    /// `clearingInput: false` reopens the panel after a region grab without losing what was typed.
    /// `catchingAudio` transcribes the last seconds of sound into the input while listening; it's
    /// set when the user opens the popup, not when another action (grab, re-grab) opens it.
    func show(clearingInput: Bool = true, catchingAudio: Bool = false) {
        // Each invocation starts with an empty input but keeps the previous reply.
        if clearingInput {
            session.clearInput()
        }
        if catchingAudio {
            catchAudio()
        }
        let rootView = QuickView(
            session: session,
            canRegrab: lastRegion != nil,
            grabRegion: { [weak self] in self?.grabRegion() },
            regrabRegion: { [weak self] in self?.regrabRegion() },
            listener: listener,
            toggleListening: { [weak self] in self?.toggleListening() },
            player: player,
            openSettings: { [weak self] in
                self?.hide()
                self?.openSettings()
            },
            continueInClaude: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.hide()
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
        if let screen {
            let visibleFrame = screen.visibleFrame
            // Top edge sits about a fifth of the way down the screen, like Spotlight.
            let top = visibleFrame.maxY - visibleFrame.height * 0.2
            panel.pinnedTop = top
            let size = hostingController.view.fittingSize
            // Centered on the full screen width: `visibleFrame` excludes a side Dock even over
            // fullscreen apps, where the Dock is hidden, which would shift the panel sideways.
            panel.setFrame(
                NSRect(x: screen.frame.midX - Self.panelWidth / 2, y: top - size.height,
                       width: Self.panelWidth, height: size.height),
                display: false
            )
        }

        Logger.panel.debug("Panel shown")
        // Makes the panel key without activating Construe, so the previous app stays frontmost.
        panel.makeKeyAndOrderFront(nil)
    }

    /// Hides the panel while the user drags out a region, then reopens it with the text read from it.
    func grabRegion() {
        hide()
        Task {
            guard let region = await RegionSelector.select() else {
                Logger.capture.info("Region selection cancelled")
                show(clearingInput: false)
                return
            }
            Logger.capture.debug("Region selected: \(String(describing: region), privacy: .public)")
            lastRegion = region
            show(clearingInput: false)
            await capture(region)
        }
    }

    /// Captures the last region again, opening the panel if it's closed (from the global shortcut).
    func regrabRegion() {
        if !panel.isVisible {
            show()
        }
        guard let lastRegion else {
            Logger.capture.notice("Re-grab with no region yet")
            let hint = KeyboardShortcuts.Name.grabRegion.shortcut.map { "Press \($0) to select one." }
                ?? "Use Grab region to select one."
            session.showImageNotice("No region yet. " + hint)
            return
        }
        Task { await capture(lastRegion) }
    }

    /// Starts or stops listening; a start failure is shown in the panel, opening it if it's closed.
    func toggleListening() {
        guard !listener.isListening else {
            listener.stop()
            return
        }
        Task {
            do {
                try await listener.start()
            } catch {
                Logger.audio.error("Listening failed to start: \(error.localizedDescription, privacy: .public)")
                if !panel.isVisible {
                    show()
                }
                session.showAudioNotice("Couldn't start listening: \(error.localizedDescription)")
            }
        }
    }

    /// Transcribes the last seconds of sound into the input. When not listening, it only reports
    /// once why listening stopped on its own, if it did.
    private func catchAudio() {
        guard listener.isListening else {
            if let reason = listener.takeStopReason() {
                session.showAudioNotice(reason)
            }
            return
        }
        guard !session.isTranscribing else { return }
        Task {
            do {
                let samples = try await listener.recentAudio()
                await session.attachAudio(samples, sampleRate: AudioRingBuffer.sampleRate) { samples in
                    try await listener.transcribe(samples)
                }
            } catch {
                Logger.audio.notice("Nothing to catch: \(error.localizedDescription, privacy: .public)")
                session.showAudioNotice(error.localizedDescription)
            }
        }
    }

    private func capture(_ region: CGRect) async {
        Logger.capture.debug("Capturing region \(String(describing: region), privacy: .public)")
        do {
            let image = try await ScreenCapturer.capture(region)
            Logger.capture.info("Captured a \(image.width)x\(image.height) image")
            await session.attachImage(image)
        } catch {
            Logger.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            session.showImageNotice("Couldn't capture the region: \(error.localizedDescription)")
        }
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
        Logger.panel.debug("Panel hidden")
        // A reply still streaming keeps going in the background and is shown on the next invocation.
        panel.orderOut(nil)
        panel.contentViewController = nil
    }
}
