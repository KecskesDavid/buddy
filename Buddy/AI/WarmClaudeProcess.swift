import Foundation

/// The `result` event of a stream-json run.
nonisolated struct ClaudeResult: Sendable {
    let text: String
    let isError: Bool
    let usage: ClaudeUsage?
}

/// Plan usage reported by Claude Code in its `rate_limit_event` (0…1).
nonisolated struct ClaudeUsage: Sendable, Equatable {
    let fiveHour: Double?
    let sevenDay: Double?

    init?(event: [String: Any]) {
        guard let info = event["rate_limit_info"] as? [String: Any],
              let windows = info["unifiedWindows"] as? [String: Any] else { return nil }
        fiveHour = (windows["five_hour"] as? [String: Any])?["utilization"] as? Double
        sevenDay = (windows["seven_day"] as? [String: Any])?["utilization"] as? Double
        if fiveHour == nil && sevenDay == nil { return nil }
    }
}

/// A `claude -p` process that is already started and waiting on stdin.
/// Starting Claude Code takes ~1.8 s, so we launch the next one ahead of time.
/// Each process answers exactly one message (no shared context between screenshots), then exits.
nonisolated final class WarmClaudeProcess: @unchecked Sendable {
    let arguments: [String]
    let createdAt = Date()
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderrLock = NSLock()
    private var stderrData = Data()
    private var didTimeOut = false

    init(executable: URL, arguments: [String], environment: [String: String]) throws {
        self.arguments = arguments
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        // Run in an empty private folder. Without this, `claude` inherits Buddy's cwd (`/`), looks around it
        // and touches ~/Music, ~/Documents, … — macOS then blames Buddy with privacy prompts
        // ("Buddy would like to access Apple Music…") and freezes `claude` until they're answered.
        process.currentDirectoryURL = Self.workingDirectory

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.terminationHandler = { finished in
            let pid = finished.processIdentifier
            let how = finished.terminationReason == .uncaughtSignal ? "killed by signal" : "exit code"
            let status = finished.terminationStatus
            DebugLog.log(status == 0 ? .app : .error, pid: pid, "claude exited · \(how) \(status)")
            DebugLog.setProcess(pid, state: nil)
        }
        try process.run()

        stdin = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading

        let pid = process.processIdentifier
        let model = arguments.firstIndex(of: "--model").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "?"
        DebugLog.log(.app, pid: pid, "started claude (\(model)) · \(executable.path) · cwd \(Self.workingDirectory.path)")
        DebugLog.setProcess(pid, state: "warm, waiting (\(model))")

        // Drain stderr continuously so it can never fill up and block the process; show it live in the console.
        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DebugLog.log(.stderr, pid: pid, String(decoding: data, as: UTF8.self))
            guard let self else { return }
            self.stderrLock.lock(); self.stderrData.append(data); self.stderrLock.unlock()
        }
    }

    var pid: Int32 { process.processIdentifier }

    var isRunning: Bool { process.isRunning }

    /// How long this process has been waiting. Long-idle processes go stale (expired login token,
    /// Claude Code auto-updated underneath, Mac slept), so the pool replaces them.
    var age: TimeInterval { Date().timeIntervalSince(createdAt) }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// SIGTERM, then SIGKILL if it's still alive 2 s later.
    func forceKill() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    /// Blocking: writes one stream-json message, reads stdout until the `result` event,
    /// then closes stdin so the process exits.
    func send(_ line: Data, timeout: TimeInterval) throws -> ClaudeResult {
        let killer = DispatchWorkItem { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.didTimeOut = true
            DebugLog.log(.error, pid: self.pid, "timed out after \(Int(timeout)) s · killing claude")
            self.forceKill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer {
            killer.cancel()
            try? stdin.close()
        }

        // Write in the background: a large image must not deadlock against unread stdout.
        let writer = stdin
        let pid = self.pid
        DebugLog.setProcess(pid, state: "answering…")
        DebugLog.log(.stdin, pid: pid, "sent message · \(line.count / 1024) KB (image not logged)")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try writer.write(contentsOf: line)
                // Close stdin right away: Claude Code (2.1.285, stdout = pipe) emits nothing until stdin hits EOF /
                // the process exits — with stdin left open every answer only appeared when the timeout killed it.
                // One message per process anyway, so EOF costs nothing.
                try writer.close()
                DebugLog.log(.stdin, pid: pid, "stdin closed (EOF)")
            } catch {
                DebugLog.log(.error, pid: pid, "writing to claude's stdin failed: \(error.localizedDescription)")
            }
        }

        var buffer = Data()
        var usage: ClaudeUsage?
        while let chunk = try? stdout.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    let text = String(decoding: lineData, as: UTF8.self)
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { DebugLog.log(.stdout, pid: pid, text) }
                    continue
                }
                let isUserEcho = object["type"] as? String == "user" // may contain the base64 screenshot
                DebugLog.log(
                    Self.isErrorEvent(object) ? .error : .stdout, pid: pid, Self.describe(object),
                    raw: isUserEcho ? nil : String(decoding: lineData, as: UTF8.self)
                )
                switch object["type"] as? String {
                case "rate_limit_event":
                    usage = ClaudeUsage(event: object) ?? usage
                case "result":
                    return ClaudeResult(
                        text: object["result"] as? String ?? "",
                        isError: object["is_error"] as? Bool ?? false,
                        usage: usage
                    )
                default:
                    continue
                }
            }
        }

        // EOF without a result.
        DebugLog.log(.error, pid: pid, "claude closed stdout without a result event")
        if didTimeOut { throw ClaudeCodeError.timedOut(timeout) }
        process.waitUntilExit()
        stderrLock.lock(); let stderr = String(decoding: stderrData, as: UTF8.self); stderrLock.unlock()
        let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            throw ClaudeCodeError.processFailed(details.isEmpty ? "exit code \(process.terminationStatus)" : details)
        }
        throw ClaudeCodeError.noResult
    }
}

extension WarmClaudeProcess {
    /// Empty folder in Buddy's temp dir (not privacy-protected), used as `claude`'s working directory.
    nonisolated static let workingDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated static func isErrorEvent(_ object: [String: Any]) -> Bool {
        (object["type"] as? String == "result" && object["is_error"] as? Bool == true)
            || (object["subtype"] as? String)?.contains("error") == true
    }

    /// One readable line per stream-json event for the Debug Console.
    nonisolated static func describe(_ object: [String: Any]) -> String {
        let type = object["type"] as? String ?? "?"
        let subtype = object["subtype"] as? String
        switch type {
        case "system" where subtype == "init":
            let model = object["model"] as? String ?? "?"
            let version = object["claude_code_version"] as? String ?? "?"
            let auth = object["apiKeySource"] as? String ?? "?"
            return "system/init · model \(model) · Claude Code \(version) · apiKeySource \(auth)"
        case "assistant":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let parts = content.map { block -> String in
                switch block["type"] as? String {
                case "text": return block["text"] as? String ?? ""
                case "thinking": return "[thinking]"
                case let other: return "[\(other ?? "?")]"
                }
            }
            return "assistant: " + parts.joined(separator: " ")
        case "rate_limit_event":
            guard let usage = ClaudeUsage(event: object) else { return "rate_limit_event" }
            let fmt = { (v: Double?) in v.map { "\(Int(($0 * 100).rounded()))%" } ?? "?" }
            return "rate limit · 5h \(fmt(usage.fiveHour)) · 7d \(fmt(usage.sevenDay))"
        case "result":
            let isError = object["is_error"] as? Bool ?? false
            let ms = object["duration_ms"] as? Int ?? 0
            let apiMs = object["duration_api_ms"] as? Int ?? 0
            let text = object["result"] as? String ?? ""
            return "result\(subtype.map { "/\($0)" } ?? "") · \(isError ? "ERROR" : "ok") · \(ms) ms (API \(apiMs) ms) · \(text)"
        default:
            return subtype.map { "\(type)/\($0)" } ?? type
        }
    }
}

/// Keeps one warm `claude` process ready for the next request.
actor ClaudeProcessPool {
    static let shared = ClaudeProcessPool()

    private var ready: WarmClaudeProcess?
    private var claudeURL: URL?
    /// A warm process older than this is thrown away instead of used (costs ~1.8 s startup once).
    private let maxIdle: TimeInterval = 10 * 60

    private func isUsable(_ process: WarmClaudeProcess?, for arguments: [String]) -> Bool {
        guard let process else { return false }
        return process.isRunning && process.arguments == arguments && process.age < maxIdle
    }

    /// Finds `claude` once and caches it.
    func executable() throws -> URL {
        if let claudeURL { return claudeURL }
        guard let url = ClaudeCodeClient.findClaude() else { throw ClaudeCodeError.notInstalled }
        claudeURL = url
        return url
    }

    /// Returns the warm process if it matches, otherwise starts a new one. Immediately warms up the next.
    func take(arguments: [String], environment: [String: String]) throws -> WarmClaudeProcess {
        let url = try executable()
        let process: WarmClaudeProcess
        if isUsable(ready, for: arguments), let ready {
            DebugLog.log(.app, pid: ready.pid, "using warm process (idle \(Int(ready.age)) s)")
            process = ready
        } else {
            if let ready {
                let why = !ready.isRunning ? "had exited" : ready.age >= maxIdle ? "stale (idle \(Int(ready.age)) s)" : "different settings"
                DebugLog.log(.app, pid: ready.pid, "warm process \(why) → starting a fresh one")
            } else {
                DebugLog.log(.app, "no warm process → starting one (≈1.8 s extra)")
            }
            ready?.terminate()
            process = try WarmClaudeProcess(executable: url, arguments: arguments, environment: environment)
        }
        ready = nil
        prewarm(arguments: arguments, environment: environment)
        return process
    }

    /// Starts a process in the background so the next request skips Claude Code's startup time.
    func prewarm(arguments: [String], environment: [String: String]) {
        if isUsable(ready, for: arguments) { return }
        ready?.terminate()
        guard let url = try? executable() else { ready = nil; return }
        ready = try? WarmClaudeProcess(executable: url, arguments: arguments, environment: environment)
    }

    func shutdown() {
        ready?.terminate()
        ready = nil
    }
}
