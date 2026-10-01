import AppKit

/// Reports global mouse movement (no permission needed for mouse events).
/// Used by the answer bubble to follow the cursor.
final class MouseTracker {
    /// Called on every mouse move, in global coordinates (points, bottom-left origin).
    var onMove: ((NSPoint) -> Void)?
    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Global: mouse moves in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.onMove?(NSEvent.mouseLocation)
        }) {
            monitors.append(global)
        }
        // Local: mouse moves while one of Clicky's own windows is active.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.onMove?(NSEvent.mouseLocation)
            return event
        }) {
            monitors.append(local)
        }
    }
}
