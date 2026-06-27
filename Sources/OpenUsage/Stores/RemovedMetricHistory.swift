import Foundation

/// One undoable metric removal: the descriptor that was turned off in Customize, plus enough position
/// info to put it back exactly where it sat. The provider's stored metric order already keeps a
/// disabled metric in its slot (so re-enabling lands it in place), but we still capture the index so
/// undo can repair the rare case where the order shifted while the metric was off (e.g. a reorder).
struct RemovedMetric: Equatable {
    let descriptorID: String
    let providerID: String
    /// The metric's index within its provider's full (enabled + disabled) metric order at removal time.
    let indexInProvider: Int
    /// Whether the metric sat below the "Shown on expand" divider when removed.
    let wasExpanded: Bool
}

/// A small, bounded undo stack for metric removals — the backing store behind `LayoutStore`'s
/// `undoLastRemove()`. Kept as its own type so the removal-undo logic doesn't push `LayoutStore`
/// further past the ~500 LOC guideline. Removals only (per issue #603); reordering is not tracked.
struct RemovedMetricHistory {
    /// How many removals can be undone. Deep enough to cover a quick burst of "off, off, off" while a
    /// user prunes their layout, shallow enough to stay a recency aid rather than a full history.
    static let maxDepth = 20

    private(set) var entries: [RemovedMetric] = []

    var canUndo: Bool { !entries.isEmpty }

    /// Record a removal as the newest undoable entry, dropping the oldest once the cap is reached.
    mutating func record(_ removal: RemovedMetric) {
        entries.append(removal)
        if entries.count > Self.maxDepth {
            entries.removeFirst(entries.count - Self.maxDepth)
        }
    }

    /// Pop the most recent removal, or `nil` when there's nothing to undo.
    mutating func popLast() -> RemovedMetric? {
        entries.popLast()
    }

    /// Forget every recorded removal — used when the layout is reset, where prior positions no longer
    /// describe the live layout and undoing into them would restore a stale arrangement.
    mutating func clear() {
        entries.removeAll()
    }

    /// Drop every recorded removal for one provider (e.g. that provider was reset on its own).
    mutating func removeAll(forProvider providerID: String) {
        entries.removeAll { $0.providerID == providerID }
    }
}
