import AppKit

/// A finished stroke, in global screen coordinates (points, bottom-left origin).
struct DrawnShape {
    let screen: NSScreen
    let points: [CGPoint]

    var bounds: CGRect { DrawnShape.boundingBox(of: points) }
    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Drawing mode: one invisible, full-screen panel per display that captures the mouse.
/// The screen itself doesn't change; the cursor becomes a crosshair; stroke is red, 3 pt.
final class DrawingController {
    var onFinish: ((DrawnShape) -> Void)?
    private(set) var isActive = false
    private var panels: [DrawingPanel] = []

    func begin() {
        guard !isActive else { return }
        removePanels(animated: false)
        isActive = true

        panels = NSScreen.screens.map { screen in
            let panel = DrawingPanel(screen: screen)
            panel.drawingView.onFinish = { [weak self] points in
                self?.finish(points: points, screen: screen)
            }
            panel.orderFrontRegardless()
            return panel
        }

        // Make the panel under the mouse key (without activating Buddy) so the crosshair shows.
        let mouse = NSEvent.mouseLocation
        (panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first)?.makeKey()
        NSCursor.crosshair.set()
    }

    /// Esc / hotkey again while drawing.
    func cancel() {
        isActive = false
        removePanels(animated: false)
        NSCursor.arrow.set()
    }

    /// Called when the answer (or an error) appears.
    func fadeOut() {
        removePanels(animated: true)
    }

    private func finish(points: [CGPoint], screen: NSScreen) {
        guard isActive else { return }
        isActive = false
        // Keep the circle visible, but let clicks go through from now on.
        for panel in panels {
            panel.ignoresMouseEvents = true
            panel.drawingView.isLocked = true
        }
        NSCursor.arrow.set()
        onFinish?(DrawnShape(screen: screen, points: points))
    }

    private func removePanels(animated: Bool) {
        let old = panels
        panels = []
        guard !old.isEmpty else { return }
        guard animated else {
            old.forEach { $0.orderOut(nil) }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            old.forEach { $0.animator().alphaValue = 0 }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            old.forEach { $0.orderOut(nil) }
        }
    }
}

final class DrawingPanel: NSPanel {
    let drawingView: DrawingView

    init(screen: NSScreen) {
        drawingView = DrawingView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        // Practically invisible, but non-zero so every pixel receives mouse events.
        backgroundColor = NSColor.black.withAlphaComponent(0.001)
        hasShadow = false
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        contentView = drawingView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

final class DrawingView: NSView {
    var onFinish: (([CGPoint]) -> Void)?
    var isLocked = false

    private var points: [CGPoint] = [] // view coordinates
    private let strokeWidth: CGFloat = 3
    /// Strokes smaller than this (both width and height) are treated as accidental and ignored.
    private let minShapeSize: CGFloat = 12

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .cursorUpdate, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        if !isLocked { NSCursor.crosshair.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        if !isLocked { NSCursor.crosshair.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        points = [convert(event.locationInWindow, from: nil)]
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isLocked, !points.isEmpty else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(p.x, bounds.minX), bounds.maxX)
        p.y = min(max(p.y, bounds.minY), bounds.maxY)
        points.append(p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isLocked, !points.isEmpty, let window else { return }
        let box = DrawnShape.boundingBox(of: points)
        if points.count < 3 || (box.width < minShapeSize && box.height < minShapeSize) {
            points = [] // accidental click — stay in drawing mode
            needsDisplay = true
            return
        }
        let origin = window.frame.origin
        onFinish?(points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) })
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        BuddyColors.stroke.setStroke()
        path.stroke()
    }
}

enum BuddyColors {
    static let stroke = NSColor(srgbRed: 1.0, green: 0.15, blue: 0.15, alpha: 1)
}
