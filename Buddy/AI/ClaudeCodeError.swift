import Foundation

nonisolated enum ClaudeCodeError: LocalizedError {
    case notInstalled
    case timedOut(TimeInterval)
    case processFailed(String)
    case apiError(String)
    case noResult
    case badFormat(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code wasn't found. Install it, run `claude` once in Terminal and log in, then try again."
        case .timedOut(let seconds):
            return "Claude Code didn't answer within \(Int(seconds)) seconds."
        case .processFailed(let details):
            return "Claude Code failed: \(details)"
        case .apiError(let message):
            // e.g. "Not logged in · Please run /login"
            return "Claude returned an error: \(message)"
        case .noResult:
            return "Claude Code finished without an answer."
        case .badFormat(let raw):
            return "Claude's answer wasn't in the expected format:\n\(raw)"
        }
    }
}
