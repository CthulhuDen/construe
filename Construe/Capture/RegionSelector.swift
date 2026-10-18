import AppKit

/// Lets the user drag out a rectangle on screen, like ⌘⇧4.
enum RegionSelector {
    /// The selection in progress; kept alive here until it finishes.
    private static var current: SelectionSession?

    /// Returns the selected rectangle in global AppKit coordinates (bottom-left origin),
    /// or `nil` if the user pressed Esc or just clicked.
    static func select() async -> CGRect? {
        await withCheckedContinuation { continuation in
            let session = SelectionSession { rect in
                current = nil
                continuation.resume(returning: rect)
            }
            current = session
            session.begin()
        }
    }
}

/// One overlay per screen; a drag stays on the screen it started on, so a region never spans displays.
private final class SelectionSession {
    private let completion: (CGRect?) -> Void
    private var overlays: [SelectionOverlay] = []

    init(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
    }

    func begin() {
        overlays = NSScreen.screens.map { screen in
            let overlay = SelectionOverlay(screen: screen)
            overlay.onFinish = { [weak self] rect in self?.finish(rect) }
            return overlay
        }
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        for overlay in overlays {
            overlay.orderFrontRegardless()
        }
        // Key status is needed for Esc; like the quick panel, this doesn't activate Construe.
        (overlays.first { $0.screen == mouseScreen } ?? overlays.first)?.makeKey()
    }

    private func finish(_ rect: CGRect?) {
        for overlay in overlays {
            overlay.orderOut(nil)
        }
        overlays = []
        completion(rect)
    }
}

/// A transparent, non-activating panel covering one screen, including fullscreen Spaces.
private final class SelectionOverlay: NSPanel {
    /// Called with the selection in screen coordinates, or `nil` when cancelled.
    var onFinish: ((CGRect?) -> Void)?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in
            guard let self else { return }
            self.onFinish?(rect.map { self.convertToScreen($0) })
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onFinish?(nil)
    }
}

private final class SelectionView: NSView {
    /// Called with the selection in view coordinates, or `nil` when it was just a click.
    var onFinish: ((CGRect?) -> Void)?

    /// Smaller drags are treated as a click and cancel the selection.
    private static let minimumSize: CGFloat = 4

    private var start: NSPoint?
    private var selection: NSRect?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.activeAlways`: Construe isn't the active app, but the crosshair should still show.
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.activeAlways, .cursorUpdate, .mouseMoved, .inVisibleRect], owner: self
        ))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        start = clamped(convert(event.locationInWindow, from: nil))
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        selection = NSRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = selection.flatMap { $0.width >= Self.minimumSize && $0.height >= Self.minimumSize ? $0 : nil }
        start = nil
        selection = nil
        onFinish?(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let selection else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}
