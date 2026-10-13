import AppKit
import SwiftUI

/// Panel that hosts the answer bubble. While listening or thinking it follows the cursor and is click-through;
/// once the answer (or an error) is in it stays put (draggable) and takes clicks and typing until closed with ×.
/// The bubble grows out of a point just below-right of the cursor.
final class BubbleController {
    /// Fixed transparent panel; the visible bubble is drawn inside it.
    static let panelSize = CGSize(width: 340, height: 360)
    /// Distance from the cursor so the bubble never covers the pointer.
    private let gap: CGFloat = 16

    let state = BubbleState()
    /// Called with each follow-up question typed into the bubble.
    var onAsk: ((String) -> Void)?
    /// Called when the user closes the bubble (× or Esc while it has focus).
    var onClose: (() -> Void)?
    private(set) var isShown = false
    /// Set when the answer arrives: the bubble stops following the cursor so it can be clicked and typed into.
    private var isPinned = false
    /// The visible bubble inside the panel (top-left origin).
    private var bubbleFrame: CGRect = .zero
    /// Mouse location and panel origin when the current drag started (screen points).
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var panel: NSPanel?

    func showListening(at mouse: NSPoint, words: String = "") {
        present(.listening(words), at: mouse, log: "listening")
    }

    /// Live words for a new question (the bubble is following the cursor).
    func showListening(_ words: String) {
        guard isShown, case .listening = state.phase else { return }
        state.phase = .listening(words)
    }

    func showThinking(at mouse: NSPoint) {
        present(.thinking, at: mouse, log: "thinking")
    }

    /// Live words of a spoken follow-up, shown in the input box.
    func setDraft(_ words: String, listening: Bool) {
        guard isShown else { return }
        state.draft = words
        state.isListening = listening
    }

    /// - Parameter question: the spoken question, shown above the answer.
    func show(_ explanation: Explanation, question: String? = nil) {
        guard isShown else {
            DebugLog.log(.error, "bubble · answer dropped: bubble isn't shown")
            return
        }
        state.question = question
        state.phase = .answer(explanation)
        pin()
        logPanel("answer")
    }

    func showError(_ message: String) {
        guard isShown else { return }
        state.phase = .error(message)
        pin()
    }

    func showFollowUpAnswer(_ text: String) {
        setLastFollowUp(.text(text))
    }

    func showFollowUpError(_ message: String) {
        setLastFollowUp(.error(message))
    }

    /// An error under the thread that isn't an answer to a question (e.g. the mic is off).
    func showNotice(_ message: String) {
        guard isShown else { return }
        state.followUps.append(.init(id: state.followUps.count, question: "", answer: .error(message)))
    }

    /// Shrinks back toward the cursor, then removes the panel.
    func hide(completion: @escaping () -> Void) {
        guard isShown else { return }
        DebugLog.log(.app, "bubble · closed")
        isShown = false
        isPinned = false
        dragStart = nil
        panel?.ignoresMouseEvents = true
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
        if isPinned {
            updateMousePassThrough(mouse)
            return
        }
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

    private func present(_ phase: BubbleState.Phase, at mouse: NSPoint, log: String) {
        let panel = panel ?? makePanel()
        self.panel = panel
        isShown = true
        isPinned = false
        panel.ignoresMouseEvents = true
        state.phase = phase
        state.question = nil
        state.followUps = []
        state.draft = ""
        state.isListening = false
        follow(mouse)
        panel.orderFrontRegardless()
        state.isVisible = true
        logPanel(log)
    }

    /// For "the bubble didn't appear" reports: says whether the window server actually shows the panel, and where.
    private func logPanel(_ phase: String) {
        guard let panel else { return }
        let f = panel.frame
        DebugLog.log(
            panel.isVisible && panel.isOnActiveSpace ? .app : .error,
            "bubble · \(phase) · on screen \(panel.isVisible) · on active Space \(panel.isOnActiveSpace) · key \(panel.isKeyWindow) · at \(Int(f.minX)),\(Int(f.minY))"
        )
    }

    /// Outside clicks don't close it, so it stops following the cursor and can be clicked, dragged and typed into.
    private func pin() {
        isPinned = true
        // Non-activating panel: takes keyboard focus for the input box without activating Buddy.
        panel?.makeKey()
        updateMousePassThrough(NSEvent.mouseLocation)
    }

    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShown, !question.isEmpty, !state.isAsking else { return }
        state.followUps.append(.init(id: state.followUps.count, question: question))
        state.draft = ""
        onAsk?(question)
    }

    /// Dragging a pinned bubble moves the whole panel. Uses the screen mouse location, not the gesture's
    /// local translation, because the view moves along with the window under the pointer.
    private func drag(ended: Bool) {
        guard isPinned, let panel else { return }
        let mouse = NSEvent.mouseLocation
        if ended {
            dragStart = nil
            updateMousePassThrough(mouse)
            return
        }
        let start = dragStart ?? (mouse, panel.frame.origin)
        dragStart = start
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func setLastFollowUp(_ answer: BubbleState.FollowUp.Answer) {
        guard isShown, !state.followUps.isEmpty else { return }
        state.followUps[state.followUps.count - 1].answer = answer
    }

    /// The panel is bigger than the bubble: only the bubble itself takes the mouse, the rest stays click-through.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard let panel, dragStart == nil else { return }
        let bubble = NSRect(
            x: panel.frame.minX + bubbleFrame.minX,
            y: panel.frame.maxY - bubbleFrame.maxY,
            width: bubbleFrame.width,
            height: bubbleFrame.height
        )
        let ignores = !(isPinned && NSMouseInRect(mouse, bubble, false))
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    private func makePanel() -> NSPanel {
        let panel = BubblePanel(
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

        let host = NSHostingView(rootView: BubbleView(
            state: state,
            onAsk: { [weak self] in self?.ask($0) },
            onDrag: { [weak self] ended in self?.drag(ended: ended) },
            onClose: { [weak self] in self?.onClose?() },
            onBubbleFrame: { [weak self] frame in
                self?.bubbleFrame = frame
                self?.updateMousePassThrough(NSEvent.mouseLocation)
            }
        ))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        return panel
    }
}

/// Borderless panels can't become key by default; the bubble must, so its input box gets the keyboard.
private final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
