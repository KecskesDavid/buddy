import AppKit

/// Tap vs hold of a set of modifier keys on their own (e.g. fn+⌃): a tap is a quick press and release,
/// a hold is still down after `holdDelay` and ends when one of the keys is let go.
///
/// Carbon hotkeys can't be modifier-only (and have no fn flag), and global key / flagsChanged monitors need
/// Accessibility, so this polls `NSEvent.modifierFlags`, which needs no permission.
/// It can't see non-modifier keys, so a shortcut like fn⌃← also looks like a tap. Arrow keys carry `.numericPad`,
/// so any gesture that shows it, or any modifier outside the set, is ignored (or, mid-hold, cancelled).
final class ModifierGesture {
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    /// `cancelled` when another modifier or an arrow key joined in during the hold.
    var onHoldEnd: ((_ cancelled: Bool) -> Void)?

    /// Short enough that a quick two-key tap is never missed, cheap enough to run all the time.
    private static let pollInterval: TimeInterval = 0.025
    private static let holdDelay: TimeInterval = 0.3
    private static let watched: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function, .numericPad]

    private enum State {
        case idle
        /// All target keys went down together at this time; not yet a tap or a hold.
        case pressed(since: Date)
        case holding
        /// Something else joined in, or the hold ended: ignore everything until all keys are up.
        case spoiled
    }

    private let modifiers: NSEvent.ModifierFlags
    private var state = State.idle
    private var timer: Timer?

    init(_ modifiers: NSEvent.ModifierFlags) {
        self.modifiers = modifiers
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = Self.pollInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let held = NSEvent.modifierFlags.intersection(Self.watched)
        let isExact = held == modifiers
        let isPartial = !held.isEmpty && modifiers.isSuperset(of: held)

        switch state {
        case .idle:
            if isExact {
                state = .pressed(since: Date())
            } else if !held.isEmpty && !isPartial {
                state = .spoiled
            }
        case .pressed(let since):
            if held.isEmpty {
                state = .idle
                onTap?()
            } else if isExact && Date().timeIntervalSince(since) >= Self.holdDelay {
                state = .holding
                onHoldStart?()
            } else if !isExact && !isPartial {
                state = .spoiled
            }
        case .holding:
            if !isExact {
                state = held.isEmpty ? .idle : .spoiled
                onHoldEnd?(!isPartial && !held.isEmpty)
            }
        case .spoiled:
            if held.isEmpty { state = .idle }
        }
    }
}
