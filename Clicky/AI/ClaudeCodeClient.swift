import Foundation

/// An image sent along with the question (e.g. JPEG screenshot with the red circle).
nonisolated struct ImageAttachment: Sendable {
    let data: Data
    let mediaType: String // "image/jpeg" or "image/png"
}

nonisolated struct ClaudeReply: Sendable {
    let explanation: Explanation
    let usage: ClaudeUsage?
}

/// Talks to Claude through the user's own installed, logged-in Claude Code CLI (`claude -p`).
/// Clicky never sees or stores Claude credentials. See plan.md → topic 2 and Spike 2.
nonisolated struct ClaudeCodeClient: Sendable {
    var model = "haiku"
    var timeout: TimeInterval = 30

    /// - Parameters:
    ///   - image: screenshot with the red circle drawn on it (nil for text-only tests).
    ///   - context: e.g. "App: Xcode — Window: ContentView.swift".
    ///   - question: what the user wants to know.
    func explain(image: ImageAttachment?, context: String, question: String) async throws -> ClaudeReply {
        let arguments = Self.arguments(model: model)
        let environment = try await Self.environment()
        let line = try Self.userMessageLine(image: image, context: context, question: question)

        // Uses the warm process (started ahead of time) and immediately warms up the next one.
        let process = try await ClaudeProcessPool.shared.take(arguments: arguments, environment: environment)
        let timeout = self.timeout

        // `send` blocks for a few seconds, so run it on a GCD thread, not the Swift concurrency pool.
        // The outer deadline is a backstop: `send` has its own timeout, but that relies on stdout reaching EOF
        // after the kill, which a lingering child process could prevent. This one always fires.
        let result: ClaudeResult = try await withDeadline(
            timeout + 5,
            onTimeout: { process.forceKill() },
            timeoutError: { ClaudeCodeError.timedOut(timeout) }
        ) {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try process.send(line, timeout: timeout))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        if result.isError { throw ClaudeCodeError.apiError(result.text) }
        return ClaudeReply(explanation: try Explanation.parse(result.text), usage: result.usage)
    }

    /// Call at launch (and whenever settings change) so the first request is fast too.
    func prewarm() async {
        guard let environment = try? await Self.environment() else { return }
        await ClaudeProcessPool.shared.prewarm(arguments: Self.arguments(model: model), environment: environment)
    }

    static func arguments(model: String) -> [String] {
        [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--system-prompt", ClickyPrompt.system,
            "--tools", "",
            "--strict-mcp-config",
            "--no-session-persistence",
            // Don't load the user's own Claude Code setup (hooks, plugins, skills, settings, Chrome):
            // it's slow, and anything in it that touches ~/Documents, ~/Desktop, network volumes, … makes
            // macOS show privacy prompts blamed on Clicky and freezes `claude` until they're answered.
            // (Not `--bare`: that only allows ANTHROPIC_API_KEY auth, no subscription login.)
            "--setting-sources", "",
            "--restricted",
            "--disable-slash-commands",
            "--no-chrome",
        ]
    }

    /// One stream-json user message: optional base64 image + text.
    static func userMessageLine(image: ImageAttachment?, context: String, question: String) throws -> Data {
        var content: [[String: Any]] = []
        if let image {
            content.append([
                "type": "image",
                "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()],
            ])
        }
        content.append(["type": "text", "text": "\(context)\n\n\(question)"])

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A) // newline-delimited JSON
        return line
    }

    /// GUI apps don't get the shell's PATH, so add the usual install locations.
    static func environment() async throws -> [String: String] {
        let claudeDirectory = try await ClaudeProcessPool.shared.executable().deletingLastPathComponent().path
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [claudeDirectory, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["MAX_THINKING_TOKENS"] = "0"
        env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = "1024"
        return env
    }

    /// Looks in the common install locations, then asks the user's login shell.
    static func findClaude() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        if let output = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"], timeout: 5),
           let path = String(decoding: output.stdout, as: UTF8.self)
               .split(separator: "\n").last
               .map({ $0.trimmingCharacters(in: .whitespaces) }),
           fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
