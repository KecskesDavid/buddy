import Foundation

/// The fixed answer format Buddy asks Claude for (see BuddyPrompt).
nonisolated struct Explanation: Decodable, Sendable, Equatable {
    let title: String
    let what: String
    let how: [String]

    var formattedBody: String {
        ([what] + how.map { "• \($0)" }).joined(separator: "\n")
    }

    /// Tolerates ```json fences or extra text: takes everything from the first `{` to the last `}`.
    static func parse(_ text: String) throws -> Explanation {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else {
            throw ClaudeCodeError.badFormat(text)
        }
        do {
            return try JSONDecoder().decode(Explanation.self, from: Data(text[start...end].utf8))
        } catch {
            throw ClaudeCodeError.badFormat(text)
        }
    }
}
