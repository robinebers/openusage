import Foundation
import os

/// Races an async operation against a wall-clock deadline and cancels the work when time runs out.
///
/// `URLRequest.timeoutInterval` only bounds idle gaps between packets, so a large response that keeps
/// trickling data (Cursor's usage CSV for heavy accounts) can run for minutes without tripping it.
/// A `TaskGroup` also cannot bound this — it still waits for a child that ignores cancellation. The
/// unstructured task + cancel pattern matches `ProviderRefreshDeadline`: when the deadline wins we
/// stop waiting and cancel best-effort; cancellation only lands where the operation cooperates
/// (URLSession's `data(for:)` does).
enum AsyncHardDeadline {
    enum Outcome<T: Sendable>: Sendable {
        case completed(T)
        case timedOut
    }

    /// `completed` with the operation's value, `timedOut` when `timeout` elapses first, or rethrows
    /// the operation's error when it fails inside the deadline. Parent-task cancellation is forwarded
    /// to the work task and surfaced as `CancellationError`.
    static func run<T: Sendable>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> Outcome<T> {
        let work = Task {
            try await operation()
        }
        let claim = ContinuationClaim()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome<T>, Error>) in
                let deadline = Task.detached {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled, claim.claim() else { return }
                    work.cancel()
                    continuation.resume(returning: .timedOut)
                }
                Task {
                    do {
                        let value = try await work.value
                        deadline.cancel()
                        guard claim.claim() else { return }
                        continuation.resume(returning: .completed(value))
                    } catch {
                        deadline.cancel()
                        guard claim.claim() else { return }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            work.cancel()
        }
    }
}

/// The one-shot right to resume a `CheckedContinuation` two tasks are racing for: the first `claim()`
/// returns true and every later one returns false. The racers run on different executors, so the
/// check-and-set has to be atomic — with a plain `Bool` both can read it as unclaimed and resume, and a
/// second resume is a fatal error, not a caught one.
private struct ContinuationClaim: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
