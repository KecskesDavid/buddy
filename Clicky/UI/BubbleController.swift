import AppKit
import SwiftUI

/// Click-through panel that follows the cursor and hosts the answer bubble.
/// The bubble grows out of a point just below-right of the cursor.
final class BubbleController {
    /// Fixed transparent panel; the visible bubble is drawn inside it.
    static let panelSize = CGSize(width: 340, height: 360)
    /// Distance from the cursor so the bubble never covers the pointer.
    private let gap: CGFloat = 16

    let state = BubbleState()
    private(set) var isShown = false
    private var panel: NSPanel?

    func showThinking(at mouse: NSPoint) {
        let panel = panel ?? makePanel()
        self.panel = panel
        isShown = true
        state.phase = .thinking
        follow(mouse)
        panel.orderFrontRegardless()
        state.isVisible = true
    }

    func show(_ explanation: Explanation) {
        guard isShown else { return }
        state.phase = .answer(explanation)
    }

    func showError(_ message: String) {
        guard isShown else { return }
        state.phase = .error(message)
    }

    /// Shrinks back toward the cursor, then removes the panel.
    func hide(completion: @escaping () -> Void) {
        guard isShown else { return }
        isShown = false
        state.isVisible = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !self.isShown else { return }
            self.panel?.orderOut(nil)
            completion()
        }
    }

    func follow(_ mouse: NSPoint) {
        guard isShown, let panel else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        let size = Self.panelSize

        let left = mouse.x + gap + size.width > frame.maxX
        let above = mouse.y - gap - size.height < frame.minY
        if state.placeLeft != left { state.placeLeft = left }
        if state.placeAbove != above { state.placeAbove = above }

        let x = left ? mouse.x - gap - size.width : mouse.x + gap
        let y = above ? mouse.y + gap : mouse.y - gap - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: BubbleView(state: state))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        return panel
    }
}
