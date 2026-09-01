import Foundation
import os

/// Runs one provider's `refresh()` under a hard deadline (#1081).
///
/// A provider that never returns — a subprocess that doesn't exit, a credential read that blocks — used
/// to hold the store's in-flight entry forever, so the dashboard spinner turned for the rest of the
/// session. The refresh therefore runs in its own task: when the deadline wins we cancel that task and
/// stop waiting for it. Structured concurrency can't do this — a `TaskGroup` still waits for a child
/// that ignores cancellation, which is exactly the case being bounded.
///
/// Cancelling the refresh is best-effort (it only lands where the provider's own work is
/// cancellation-aware). What the deadline guarantees is that the *store* stops waiting.
@MainActor
enum ProviderRefreshDeadline {
    /// The refreshed snapshot, or `nil` if `timeout` elapsed first.
    static func snapshot(
        from provider: ProviderRuntime,
        force: Bool,
        timeout: TimeInterval
    ) async -> ProviderSnapshot? {
        let work = Task { @MainActor in
            await ProviderRefreshContext.$isManual.withValue(force) {
                await provider.refresh()
            }
        }
        let claim = ContinuationClaim()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProviderSnapshot?, Never>) in
                // Detached, so a busy MainActor can't delay the one thing that bounds the wait.
                let deadline = Task.detached {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled, claim.claim() else { return }
                    work.cancel()
                    continuation.resume(returning: nil)
                }
                Task { @MainActor in
                    let snapshot = await work.value
                    // Cancel the deadline the moment the snapshot lands, so a fast refresh doesn't leave
                    // a timer sleeping per provider until it expires.
                    deadline.cancel()
                    guard claim.claim() else { return }
                    continuation.resume(returning: snapshot)
                }
            }
        } onCancel: {
            // An unstructured task doesn't inherit cancellation, so forward the caller's explicitly —
            // otherwise a cancelled refresh pass would leave its provider work running.
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
