import Foundation
import Observation

nonisolated enum DebugSource: String, Sendable {
    case app, stdin, stdout, stderr, error
}

nonisolated struct DebugEntry: Identifiable, Sendable {
    let id: Int
    let date: Date
    let source: DebugSource
    let pid: Int32?
    let text: String
    /// Raw JSON line from `claude`, shown when "Raw JSON" is on.
    let raw: String?
}

/// In-memory log of what Clicky and its `claude` processes are doing, shown in the Debug Console.
/// Privacy: memory only, never written to disk, cleared on quit. The screenshot itself is never
/// logged — only its size.
@Observable
final class DebugLog {
    static let shared = DebugLog()

    private(set) var entries: [DebugEntry] = []
    /// Live `claude` processes: pid → state ("warm, waiting", "answering…").
    private(set) var processes: [Int32: String] = [:]

    @ObservationIgnored private var nextID = 0
    private let limit = 1500
    nonisolated private static let rawLimit = 4000

    // MARK: - Thread-safe entry points (called from GCD threads reading pipes)

    nonisolated static func log(_ source: DebugSource, pid: Int32? = nil, _ text: String, raw: String? = nil) {
        let date = Date()
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = raw.map { $0.count > rawLimit ? String($0.prefix(rawLimit)) + " …(truncated)" : $0 }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                shared.add(date: date, source: source, pid: pid, text: text, raw: raw)
            }
        }
    }

    /// `state == nil` removes the process (it exited).
    nonisolated static func setProcess(_ pid: Int32, state: String?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                shared.processes[pid] = state
            }
        }
    }

    // MARK: - Main actor

    private func add(date: Date, source: DebugSource, pid: Int32?, text: String, raw: String?) {
        nextID += 1
        entries.append(DebugEntry(id: nextID, date: date, source: source, pid: pid, text: text, raw: raw))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func clear() { entries.removeAll() }

    var plainText: String {
        entries.map { entry in
            let time = entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
            let pid = entry.pid.map { " [\($0)]" } ?? ""
            return "\(time) \(entry.source.rawValue)\(pid) \(entry.text)" + (entry.raw.map { "\n    \($0)" } ?? "")
        }
        .joined(separator: "\n")
    }
}
