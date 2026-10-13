import AppKit
import Carbon.HIToolbox
import Observation

/// Which Claude model Buddy asks. Persisted in UserDefaults.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case haiku, sonnet
    var id: String { rawValue }
    var label: String {
        switch self {
        case .haiku: "Haiku"
        case .sonnet: "Sonnet"
        }
    }
    var detail: String {
        switch self {
        case .haiku: "Fast"
        case .sonnet: "Smarter, slower"
        }
    }
}

/// Shared app state and the MVP flow:
/// fn⌃ tap → draw → capture screen + circle → Claude → answer bubble next to the cursor.
/// Holding fn⌃ instead also listens for a spoken question (plan.md topic 13).
@Observable
final class AppModel {
    static let shared = AppModel()

    let mouse = MouseTracker()
    let drawing = DrawingController()
    let bubble = BubbleController()
    let listener = SpeechListener()

    private(set) var model: ClaudeModel =
        ClaudeModel(rawValue: UserDefaults.standard.string(forKey: "model") ?? "") ?? .haiku

    @ObservationIgnored private var drawKeys: ModifierGesture?
    @ObservationIgnored private var escHotKey: HotKey?
    /// Bumped on every new request / cancel, so late answers from old requests are ignored.
    @ObservationIgnored private var requestID = 0
    /// The open bubble's capture and turns, resent with each follow-up. In memory only, dropped when the bubble closes.
    @ObservationIgnored private var conversation: Conversation?
    /// The fn⌃ hold in progress, from the press until it's sent or cancelled.
    @ObservationIgnored private var hold: Hold?

    /// Listening runs until the keys are up and the circle is done; with an answer open and no circle,
    /// it's a follow-up and ends with the keys.
    private struct Hold {
        var isFollowUp: Bool
        var keysReleased = false
        var shape: DrawnShape?
    }

    private struct Conversation {
        let image: ImageAttachment
        let context: String
        var turns: [(question: String, answer: String)]
    }

    private static let firstQuestion = "Explain what I circled."

    private var claude: ClaudeCodeClient { ClaudeCodeClient(model: model.rawValue) }

    // MARK: - Lifecycle

    func start() {
        mouse.onMove = { [weak self] location in self?.bubble.follow(location) }
        mouse.start()

        drawing.onStart = { [weak self] in self?.circleStarted() }
        drawing.onFinish = { [weak self] shape in self?.circleFinished(shape) }
        bubble.onAsk = { [weak self] question in self?.askFollowUp(question) }
        bubble.onClose = { [weak self] in self?.closeBubble() }
        listener.onText = { [weak self] words in self?.heard(words) }
        listener.onDownloading = { [weak self] in self?.heard("Downloading the speech model…") }
        listener.onError = { [weak self] error in self?.listeningFailed(error) }

        let drawKeys = ModifierGesture([.function, .control])
        drawKeys.onTap = { [weak self] in self?.toggleDrawing() }
        drawKeys.onHoldStart = { [weak self] in self?.startHold() }
        drawKeys.onHoldEnd = { [weak self] cancelled in
            if cancelled { self?.cancelAll() } else { self?.keysReleased() }
        }
        drawKeys.start()
        self.drawKeys = drawKeys

        // Registered only while drawing mode or the bubble is open (a global key monitor would need Accessibility).
        escHotKey = HotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in
            self?.cancelAll()
        }

        // Screen Recording is requested on the first capture (see ScreenCapturer).

        // Start a Claude Code process now, so the first request doesn't pay the ~1.8 s startup.
        let client = claude
        Task { await client.prewarm() }
    }

    // MARK: - Model

    func setModel(_ newModel: ClaudeModel) {
        guard newModel != model else { return }
        model = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: "model")
        let client = claude
        Task { await client.prewarm() } // replaces the warm process with one for the new model
    }

    // MARK: - Drawing flow

    func toggleDrawing() {
        if drawing.isActive {
            cancelAll()
            return
        }
        if bubble.isShown { closeBubble() }
        drawing.begin()
        escHotKey?.register()
    }

    // MARK: - Voice (hold fn⌃)

    private func startHold() {
        // Held again before circling after an earlier release: keep listening.
        if var hold {
            hold.keysReleased = false
            self.hold = hold
            return
        }
        let isFollowUp = conversation != nil && bubble.isShown && !drawing.isActive
        if isFollowUp {
            bubble.setDraft("", listening: true)
            drawing.begin()
        } else {
            // A tap may have started drawing mode already; the words then go with that circle.
            if !drawing.isActive {
                if bubble.isShown { closeBubble() }
                drawing.begin()
            }
            bubble.showListening(at: NSEvent.mouseLocation)
        }
        escHotKey?.register()
        hold = Hold(isFollowUp: isFollowUp)
        listener.start()
        DebugLog.log(.app, "voice · hold started\(isFollowUp ? " (follow-up)" : "")")
    }

    private func heard(_ words: String) {
        guard let hold else { return }
        if hold.isFollowUp {
            bubble.setDraft(words, listening: true)
        } else {
            bubble.showListening(words)
        }
    }

    /// Circling during a follow-up hold asks a new question about the new circle instead.
    private func circleStarted() {
        guard var hold, hold.isFollowUp else { return }
        hold.isFollowUp = false
        self.hold = hold
        requestID += 1
        conversation = nil
        bubble.showListening(at: NSEvent.mouseLocation, words: listener.text)
    }

    private func circleFinished(_ shape: DrawnShape) {
        guard var hold else {
            explain(shape)
            return
        }
        hold.shape = shape
        self.hold = hold
        if hold.keysReleased { sendHold() }
    }

    private func keysReleased() {
        guard var hold else { return }
        hold.keysReleased = true
        self.hold = hold
        if hold.isFollowUp || hold.shape != nil { sendHold() }
    }

    private func sendHold() {
        guard let hold else { return }
        self.hold = nil
        let listener = listener
        let spoken = Task { await listener.finish() }
        if let shape = hold.shape {
            explain(shape, spoken: spoken)
            return
        }
        // Follow-up: no circle, just the words.
        drawing.cancel()
        releaseEsc()
        bubble.setDraft(listener.text, listening: false)
        let id = requestID
        Task {
            let question = await spoken.value
            guard id == requestID else { return }
            if question.isEmpty {
                bubble.setDraft("", listening: false)
            } else {
                bubble.ask(question)
            }
        }
    }

    private func listeningFailed(_ error: Error) {
        guard let hold else { return }
        self.hold = nil
        DebugLog.log(.error, "voice · \(error.localizedDescription)")
        if drawing.isActive { drawing.cancel() }
        releaseEsc()
        if hold.isFollowUp {
            bubble.setDraft("", listening: false)
            bubble.showNotice(error.localizedDescription)
        } else {
            requestID += 1
            drawing.fadeOut()
            bubble.showError(error.localizedDescription)
        }
    }

    // MARK: - Asking Claude

    /// - Parameter spoken: the words from a hold, still being finished while the screen is captured.
    private func explain(_ shape: DrawnShape, spoken: Task<String, Never>? = nil) {
        requestID += 1
        let id = requestID

        bubble.showThinking(at: NSEvent.mouseLocation)
        let client = claude

        DebugLog.log(.app, "request #\(id) · circle drawn → capturing screen")

        Task {
            let started = Date()
            do {
                let screen = shape.screen
                let screenshot = try await withDeadline(10, timeoutError: { CaptureError.timedOut }) {
                    try await ScreenCapturer.capture(screen: screen)
                }
                guard let annotated = ScreenshotAnnotator.annotate(screenshot, with: shape),
                      let jpeg = ScreenshotAnnotator.jpegData(annotated) else {
                    throw CaptureError.encodingFailed
                }
                let context = WindowContext.describe(at: shape.center)
                let captured = Date()
                DebugLog.log(.app, "request #\(id) · captured \(jpeg.count / 1024) KB in \(String(format: "%.2f", captured.timeIntervalSince(started))) s · \(context) → asking Claude (\(client.model))")
                let image = ImageAttachment(data: jpeg, mediaType: "image/jpeg")
                let heard = await spoken?.value ?? ""
                let question = heard.isEmpty ? Self.firstQuestion : heard
                if !heard.isEmpty { DebugLog.log(.app, "request #\(id) · spoken question: \(heard)") }
                let reply = try await client.explain(image: image, context: context, question: question)
                print(String(
                    format: "[Buddy] capture %.2f s · Claude %.2f s · total %.2f s · %ld KB image",
                    captured.timeIntervalSince(started), Date().timeIntervalSince(captured),
                    Date().timeIntervalSince(started), jpeg.count / 1024
                ))
                DebugLog.log(.app, "request #\(id) · answer in \(String(format: "%.2f", Date().timeIntervalSince(captured))) s: \(reply.explanation.title)")
                guard id == requestID else {
                    DebugLog.log(.app, "request #\(id) · answer ignored (cancelled or replaced)")
                    return
                }
                drawing.fadeOut()
                conversation = Conversation(
                    image: image,
                    context: context,
                    turns: [(question, "\(reply.explanation.title): \(reply.explanation.what)")]
                )
                bubble.show(reply.explanation, question: heard.isEmpty ? nil : heard)
                releaseEsc()
            } catch {
                DebugLog.log(.error, "request #\(id) · \(error.localizedDescription)")
                guard id == requestID else { return }
                drawing.fadeOut()
                bubble.showError(error.localizedDescription)
                releaseEsc()
            }
        }
    }

    /// A question typed into the bubble: same screenshot and context, plus the earlier turns.
    private func askFollowUp(_ question: String) {
        guard let conversation else { return }
        let id = requestID
        let client = claude
        DebugLog.log(.app, "request #\(id) · follow-up \(conversation.turns.count) → asking Claude (\(client.model))")

        Task {
            let started = Date()
            do {
                let reply = try await client.explain(
                    image: conversation.image,
                    context: conversation.context,
                    question: BuddyPrompt.followUp(question, after: conversation.turns)
                )
                DebugLog.log(.app, "request #\(id) · follow-up answer in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                guard id == requestID else {
                    DebugLog.log(.app, "request #\(id) · follow-up answer ignored (bubble closed)")
                    return
                }
                self.conversation?.turns.append((question, reply.explanation.what))
                bubble.showFollowUpAnswer(reply.explanation.what)
            } catch {
                DebugLog.log(.error, "request #\(id) · follow-up · \(error.localizedDescription)")
                guard id == requestID else { return }
                bubble.showFollowUpError(error.localizedDescription)
            }
        }
    }

    /// Esc: cancels drawing mode or a pending request.
    func cancelAll() {
        requestID += 1
        hold = nil
        listener.cancel()
        if drawing.isActive { drawing.cancel() }
        closeBubble()
    }

    private func closeBubble() {
        requestID += 1
        conversation = nil
        escHotKey?.unregister()
        drawing.fadeOut()
        bubble.hide {}
    }

    /// The answer bubble stays open until × (or Esc while it has focus), so the global Esc hotkey is given back:
    /// keeping it would swallow Esc in every other app for as long as the bubble is on screen.
    private func releaseEsc() {
        escHotKey?.unregister()
    }
}
