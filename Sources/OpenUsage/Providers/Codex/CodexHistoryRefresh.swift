import Foundation

/// A single local scan can outlive a quota refresh. Never start overlapping scans, and consume the
/// completed result on the next refresh if it misses this one's short wait budget. Unlike a task
/// group, this bounded wait does not wait for a scanner that ignores cancellation to unwind.
@MainActor
final class CodexHistoryRefresh<Value: Sendable> {
    private var task: Task<Void, Never>?
    private var completed: Value?

    deinit { task?.cancel() }

    func value(wait: Duration, operation: @escaping @MainActor () async -> Value) async -> Value? {
        guard !Task.isCancelled else { return nil }
        if task == nil {
            task = Task { [weak self] in
                let value = await operation()
                guard !Task.isCancelled else { return }
                self?.completed = value
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while completed == nil && clock.now < deadline && !Task.isCancelled {
            // Only active while waiting for a scan, never an idle application timer.
            try? await Task.sleep(for: min(.milliseconds(25), clock.now.duration(to: deadline)))
        }
        guard !Task.isCancelled, let result = completed else { return nil }
        completed = nil
        task = nil
        return result
    }
}
