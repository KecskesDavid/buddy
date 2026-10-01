import AppKit

/// Text context sent next to the screenshot: app name + window title of the window under the circle.
enum WindowContext {
    /// - Parameter point: global coordinates (points, bottom-left origin), e.g. the circle's center.
    static func describe(at point: CGPoint) -> String {
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        // CGWindowList uses a top-left origin relative to the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            // Front-to-back order: the first normal window containing the point is the one under the circle.
            for info in list {
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                      bounds.contains(cgPoint) else { continue }

                let app = info[kCGWindowOwnerName as String] as? String ?? "Unknown app"
                if let title = info[kCGWindowName as String] as? String, !title.isEmpty {
                    return "App: \(app) — Window: \(title)"
                }
                return "App: \(app)"
            }
        }

        if let front = NSWorkspace.shared.frontmostApplication?.localizedName {
            return "App: \(front)"
        }
        return "App: unknown"
    }
}
