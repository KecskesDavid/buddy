import Foundation

/// Resumes a continuation exactly once — whichever of "finished" / "deadline hit" comes first wins.
nonisolated final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Runs `operation`, but gives up after `seconds` even if the operation never returns
/// (ScreenCaptureKit stuck on a permission state, a pipe read that never sees EOF, …).
/// A task group can't guarantee this: it waits for children that ignore cancellation.
nonisolated func withDeadline<T>(
    _ seconds: TimeInterval,
    onTimeout: @escaping @Sendable () -> Void = {},
    timeoutError: @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        let task = Task {
            do { once.resume(with: .success(try await operation())) }
            catch { once.resume(with: .failure(error)) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            task.cancel()
            onTimeout()
            once.resume(with: .failure(timeoutError()))
        }
    }
}
