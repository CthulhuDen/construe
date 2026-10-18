import AppKit

/// A borderless, non-activating floating panel, similar to Spotlight or 1Password's quick access.
///
/// Being non-activating means it can take keyboard focus without making Construe the active app,
/// so the app you were using (even a fullscreen one) stays frontmost and regains focus on dismiss.
final class QuickPanel: NSPanel {
    /// Called when the user presses Esc.
    var onCancel: (() -> Void)?
    /// Called when the panel loses key status, e.g. the user clicked elsewhere.
    var onResignKey: (() -> Void)?

    /// When set, frame changes keep this top edge fixed so the panel grows downward.
    var pinnedTop: CGFloat?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
    }

    // Borderless windows can't become key by default; the panel needs key status for text input.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let pinnedTop {
            frame.origin.y = pinnedTop - frame.height
        }
        super.setFrame(frame, display: flag)
    }
}
