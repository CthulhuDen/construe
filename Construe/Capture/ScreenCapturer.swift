import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case permissionDenied
    case regionOffScreen

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Allow Construe in System Settings > Privacy & Security > Screen & System Audio Recording, "
                + "then try again. You may need to quit and reopen Construe."
        case .regionOffScreen:
            "The saved region is no longer on screen. Grab a new one."
        }
    }
}

/// Captures a region of the screen with ScreenCaptureKit, leaving out Construe's own windows.
enum ScreenCapturer {
    /// Captures `rect` (global AppKit coordinates, on a single screen) at the display's full resolution.
    static func capture(_ rect: CGRect) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw CaptureError.regionOffScreen }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.regionOffScreen
        }
        // Excluding Construe keeps the popup out of the image, so Re-grab works with it open.
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter { $0.processID == ownProcess },
            exceptingWindows: []
        )

        let region = displayLocalRect(rect.intersection(screen.frame), screenFrame: screen.frame)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region
        configuration.width = Int((region.width * screen.backingScaleFactor).rounded())
        configuration.height = Int((region.height * screen.backingScaleFactor).rounded())
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Converts `rect` from global AppKit coordinates (bottom-left origin) to points relative to the
    /// top-left corner of the screen with frame `screenFrame`, as `SCStreamConfiguration.sourceRect` expects.
    static func displayLocalRect(_ rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
