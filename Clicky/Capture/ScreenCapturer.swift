import AppKit
import ScreenCaptureKit

nonisolated enum CaptureError: LocalizedError {
    case noPermission
    case displayNotFound
    case encodingFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Clicky needs Screen Recording permission. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Clicky."
        case .displayNotFound:
            return "Couldn't find the display to capture."
        case .encodingFailed:
            return "Couldn't prepare the screenshot."
        case .timedOut:
            return "Taking the screenshot got stuck. Check that Clicky has Screen Recording permission, then quit and reopen Clicky."
        }
    }
}

/// Captures the whole display (without Clicky's own windows), scaled to Claude's recommended size.
enum ScreenCapturer {
    static let maxLongEdge: CGFloat = 1568

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards the user must enable it in System Settings.
    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    static func capture(screen: NSScreen) async throws -> CGImage {
        guard let displayID = screen.displayID else { throw CaptureError.displayNotFound }

        // Don't gate on CGPreflightScreenCaptureAccess(): it can report a stale "no" for local dev builds.
        // Just try, and only blame the permission if capturing actually fails.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if !hasPermission {
                requestPermission()
                throw CaptureError.noPermission
            }
            throw error
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let size = targetPixelSize(for: screen)
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Native pixel size, scaled down so the long edge is at most `maxLongEdge`.
    static func targetPixelSize(for screen: NSScreen) -> CGSize {
        let pixels = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
        let scale = min(1, maxLongEdge / max(pixels.width, pixels.height))
        return CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
