import AVFoundation
import Speech

/// Turns the spoken question into text, on the Mac, with macOS 26 `SpeechAnalyzer` + `SpeechTranscriber`.
/// Audio goes from the mic straight into Apple's on-device model: nothing leaves the Mac or touches disk
/// (Claude Code can't take audio anyway). One `start()` … `finish()` / `cancel()` per hold.
final class SpeechListener {
    /// Everything heard so far (finished + in-progress words), for the live bubble.
    var onText: ((String) -> Void)?
    /// The speech model has to be downloaded first (once per language), which can take a while.
    var onDownloading: (() -> Void)?
    var onError: ((Error) -> Void)?

    /// The mic turns off by itself after this long; what was heard is kept.
    private static let maxDuration: Duration = .seconds(30)

    private var finished: [String] = []
    private var inProgress = ""
    /// Bumped by every start / cancel, so work from an older hold stops touching state.
    private var session = 0
    private var starting: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    /// The Mac's language if Apple supports it, else English; looked up once.
    private var locale: Locale?

    var text: String {
        (finished + [inProgress])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func start() {
        cancel()
        let session = session
        starting = Task { [weak self] in
            do {
                try await self?.begin(session)
            } catch {
                guard let self, session == self.session else { return }
                self.cancel()
                self.onError?(error is VoiceError ? error : VoiceError.failed(error.localizedDescription))
            }
        }
    }

    /// Stops the mic, lets the model finish the last words, and returns everything heard ("" if nothing).
    func finish() async -> String {
        let session = session
        await starting?.value
        guard session == self.session else { return "" }
        stopAudio()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        await results?.value
        guard session == self.session else { return "" }
        let heard = text
        reset()
        return heard
    }

    func cancel() {
        session += 1
        stopAudio()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        reset()
    }

    private func reset() {
        starting = nil
        results?.cancel()
        results = nil
        analyzer = nil
        finished = []
        inProgress = ""
    }

    private func begin(_ session: Int) async throws {
        try await Self.requestMicAccess()
        guard SpeechTranscriber.isAvailable else { throw VoiceError.unavailable }
        let locale = try await resolvedLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            if session == self.session { onDownloading?() }
            try await download.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.unavailable
        }
        guard session == self.session else { return }

        // Start the mic before the analyzer: buffers wait in the stream, so the first words aren't lost.
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let engine = AVAudioEngine()
        try Self.feed(engine.inputNode, into: input, as: format)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.input = input

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .lingering)
        )
        self.analyzer = analyzer
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, session == self.session else { return }
                    let words = String(result.text.characters)
                    if result.isFinal {
                        self.finished.append(words)
                        self.inProgress = ""
                    } else {
                        self.inProgress = words
                    }
                    self.onText?(self.text)
                }
            } catch {
                DebugLog.log(.error, "voice · results · \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)

        Task { [weak self] in
            try? await Task.sleep(for: Self.maxDuration)
            guard let self, session == self.session else { return }
            self.stopAudio()
        }
        DebugLog.log(.app, "voice · listening (\(locale.identifier))")
    }

    private func resolvedLocale() async throws -> Locale {
        if let locale { return locale }
        let found = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        let english = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        guard let resolved = found ?? english else { throw VoiceError.unavailable }
        locale = resolved
        return resolved
    }

    private func stopAudio() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        input?.finish()
        input = nil
    }

    private static func requestMicAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw VoiceError.micDenied
        default:
            throw VoiceError.micDenied
        }
    }

    /// The tap block runs on the audio thread, so it's built in a nonisolated context.
    nonisolated private static func feed(
        _ node: AVAudioInputNode,
        into input: AsyncStream<AnalyzerInput>.Continuation,
        as format: AVAudioFormat
    ) throws {
        let micFormat = node.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw VoiceError.noMicrophone }
        guard let converter = AVAudioConverter(from: micFormat, to: format) else {
            throw VoiceError.failed("unsupported microphone format")
        }
        let ratio = format.sampleRate / micFormat.sampleRate
        node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            guard capacity > 0, let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var isConsumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if isConsumed {
                    status.pointee = .noDataNow
                    return nil
                }
                isConsumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil && converted.frameLength > 0 {
                input.yield(AnalyzerInput(buffer: converted))
            }
        }
    }
}
