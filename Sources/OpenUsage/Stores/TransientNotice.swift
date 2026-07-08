import Observation

/// A small auto-clearing UI notice — the "shown for a couple of seconds, then it clears itself" pill.
/// One reusable box for what used to be three copy-pasted machines in `LayoutStore` (the pin-denial
/// notice, the "Copied to clipboard" share confirmation, and the Customize action notice), each of which
/// was a value + a replay-trigger counter + a clear `Task`.
///
/// `present(_:)` sets the value, bumps `trigger` (so a view keyed on it replays its pop-in even when the
/// value is unchanged — e.g. the same denial twice in a row), and (re)starts the auto-clear timer.
/// `clear()` resets immediately and cancels the timer — call it on popover close so a pill mid-countdown
/// can't reappear stale on the next open (the store outlives the popover).
@MainActor
@Observable
final class TransientNotice<Value> {
    private(set) var value: Value
    /// Bumped on every `present` so a `.id(trigger)`-keyed view replays its transition each time.
    private(set) var trigger = 0

    // `let`s are never observation-tracked; only the mutable task needs the annotation.
    private let clearedValue: Value
    private let timeout: Duration
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    /// - Parameters:
    ///   - clearedValue: the resting value shown when nothing is presented (e.g. `nil` / `false`).
    ///   - timeout: how long a presented value stays before it auto-clears.
    init(clearedValue: Value, timeout: Duration) {
        self.value = clearedValue
        self.clearedValue = clearedValue
        self.timeout = timeout
    }

    func present(_ newValue: Value) {
        value = newValue
        trigger += 1
        clearTask?.cancel()
        let timeout = self.timeout
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            value = clearedValue
        }
    }

    func clear() {
        value = clearedValue
        clearTask?.cancel()
        clearTask = nil
    }
}
