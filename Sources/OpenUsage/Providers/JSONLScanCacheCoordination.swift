import Foundation

/// One scanner-wide I/O budget shared by every provider/home identity. Without this pool, eight parse
/// tasks per identity can multiply into dozens of simultaneous reads during multi-account launch.
actor JSONLParsePermitPool {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.available = limit
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            available += 1
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

enum PersistentJSONLScanCaches {
    /// A one-shot CLI has no run loop to outlive the debounce, so it explicitly drains every local-log
    /// parser before returning. Scanners without pending work return immediately.
    static func flushPendingWrites() async {
        await ClaudeLogUsageScanner.flushPersistentCacheWrites()
        await CodexLogUsageScanner.flushPersistentCacheWrites()
        await PiUsageScanner.flushPersistentCacheWrites()
    }
}
