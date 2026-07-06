import Foundation

/// The refresh loop's between-passes wait: sleeps one refresh interval, but wakes early when the
/// enabled-provider set changes — and, crucially, never loses a change that lands *during* a pass.
///
/// The bug this replaces: the loop used to subscribe to
/// `ProviderEnablementStore.didChangeNotification` only inside its wait, after `refreshAll()` had
/// finished. First-run credential detection is local-only and fast while the first refresh pass does
/// network I/O and is slow, so the "providers enabled" notification almost always fired mid-pass with
/// nobody listening — `NotificationCenter.notifications(named:)` doesn't buffer events from before
/// iteration starts. The wake was silently dropped and the newly detected providers sat dataless until
/// the next scheduled pass or a manual refresh. The same lost wake hit `NewProviderSeeder` and the
/// Customize "Reset All" reseed.
///
/// Here the subscription is installed once, synchronously, in `init` — before the loop's first pass —
/// feeding an `AsyncStream` with `.bufferingNewest(1)`: a wake posted while nobody is waiting is
/// retained, and a burst coalesces into a single pending wake, so the next `waitForWake` returns
/// immediately instead of sleeping out the interval.
@MainActor
final class RefreshWakeSignal {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let center: NotificationCenter
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can unregister the observer; it is immutable
    /// after `init`, and `NotificationCenter` is documented thread-safe.
    private nonisolated(unsafe) let observer: NSObjectProtocol

    init(
        name: Notification.Name = ProviderEnablementStore.didChangeNotification,
        center: NotificationCenter = .default
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
        self.center = center
        // Registered synchronously, so no notification posted after `init` returns can be missed.
        // The continuation is `Sendable`; yielding from whatever context posts is safe.
        self.observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            continuation.yield()
        }
    }

    deinit {
        center.removeObserver(observer)
        continuation.finish()
    }

    /// Returns when a wake has been posted — including one buffered while the caller was doing other
    /// work — or when `timeout` elapses, whichever comes first (the timer feeds the same stream). Also
    /// returns promptly when the surrounding task is cancelled. If the timeout and a wake race, the
    /// loser stays buffered; the resulting extra pass is all cache hits, so it stays harmless.
    ///
    /// The refresh loop is the signal's only consumer, and only ever sequentially: each call makes a
    /// fresh iterator over the shared stream (fine sequentially — the buffer lives on the stream), so
    /// no actor-isolated iterator state has to survive a suspension.
    func waitForWake(timeout: TimeInterval) async {
        let timer = Task { [continuation] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            continuation.yield()
        }
        defer { timer.cancel() }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}
