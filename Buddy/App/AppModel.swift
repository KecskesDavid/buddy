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
/// ⌃⌥Space → draw → capture screen + circle → Claude → answer bubble next to the cursor.
@Observable
final class AppModel {
    static let shared = AppModel()

    let mouse = MouseTracker()
    let drawing = DrawingController()
    let bubble = BubbleController()

    private(set) var isDrawHotKeyRegistered = false
    private(set) var model: ClaudeModel =
        ClaudeModel(rawValue: UserDefaults.standard.string(forKey: "model") ?? "") ?? .haiku

    @ObservationIgnored private var drawHotKey: HotKey?
    @ObservationIgnored private var escHotKey: HotKey?
    @ObservationIgnored private var clickMonitors: [Any] = []
    /// Bumped on every new request / cancel, so late answers from old requests are ignored.
    @ObservationIgnored private var requestID = 0

    private var claude: ClaudeCodeClient { ClaudeCodeClient(model: model.rawValue) }

    // MARK: - Lifecycle

    func start() {
        mouse.onMove = { [weak self] location in self?.bubble.follow(location) }
        mouse.start()

        drawing.onFinish = { [weak self] shape in self?.explain(shape) }

        let drawKey = HotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggleDrawing()
        }
        isDrawHotKeyRegistered = drawKey.register()
        drawHotKey = drawKey

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

    private func explain(_ shape: DrawnShape) {
        requestID += 1
        let id = requestID

        bubble.showThinking(at: NSEvent.mouseLocation)
        addClickMonitors()
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
                let reply = try await client.explain(
                    image: ImageAttachment(data: jpeg, mediaType: "image/jpeg"),
                    context: context,
                    question: "Explain what I circled."
                )
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
                bubble.show(reply.explanation)
            } catch {
                DebugLog.log(.error, "request #\(id) · \(error.localizedDescription)")
                guard id == requestID else { return }
                drawing.fadeOut()
                bubble.showError(error.localizedDescription)
            }
        }
    }

    /// Esc: cancels drawing mode, a pending request, or closes the bubble.
    func cancelAll() {
        requestID += 1
        if drawing.isActive { drawing.cancel() }
        closeBubble()
    }

    private func closeBubble() {
        requestID += 1
        removeClickMonitors()
        escHotKey?.unregister()
        drawing.fadeOut()
        bubble.hide {}
    }

    /// Any click closes the bubble; the click still reaches the app underneath.
    private func addClickMonitors() {
        removeClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.closeBubble()
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.closeBubble()
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func removeClickMonitors() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors = []
    }
}
