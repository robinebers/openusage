import Foundation

/// An immutable capture of every piece of layout state a user action can change — the unit the undo
/// stack stores. Rather than record a bespoke inverse per action type (remove vs. reorder vs. pin),
/// undo snapshots this whole slice before each change and restores it wholesale, so every action kind
/// is undoable through one code path and the restore is always exact (interlocking state — order,
/// expanded membership, and pins all move together — can't drift out of sync).
///
/// Equatable so the store can skip pushing a snapshot when an action turned out to be a no-op.
struct LayoutSnapshot: Equatable {
    let placed: [PlacedWidget]
    let providerOrder: [String]
    let metricOrderByProvider: [String: [String]]
    let pinnedMetricIDs: Set<String>
    let expandedMetricIDs: Set<String>
    let defaultExpandedOnEnableIDs: Set<String>
}

/// A small, bounded undo stack of `LayoutSnapshot`s — the machinery behind `LayoutStore`'s app-wide
/// ⌘Z. Kept as its own type so the history logic doesn't push `LayoutStore` past the ~500 LOC
/// guideline. Session-scoped (the store never persists it). Covers every customization action that
/// flows through the store's user-facing mutations; reverting reorder, pin/unpin, show/hide all reduce
/// to restoring an earlier snapshot.
struct LayoutUndoHistory {
    /// How many steps ⌘Z can walk back. Deep enough to cover a real editing session (prune a few rows,
    /// reorder, pin) without growing unbounded; snapshots are small value types so the memory cost is
    /// negligible at this depth.
    static let maxDepth = 40

    private(set) var snapshots: [LayoutSnapshot] = []

    var canUndo: Bool { !snapshots.isEmpty }

    /// Push a pre-change snapshot as the newest undo step, dropping the oldest once the cap is reached.
    mutating func record(_ snapshot: LayoutSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > Self.maxDepth {
            snapshots.removeFirst(snapshots.count - Self.maxDepth)
        }
    }

    /// Pop the most recent snapshot to restore, or `nil` when there's nothing to undo.
    mutating func popLast() -> LayoutSnapshot? {
        snapshots.popLast()
    }

    /// Forget every recorded step — used when the layout is reset, where prior snapshots describe a
    /// pre-reset arrangement that undoing into would resurrect.
    mutating func clear() {
        snapshots.removeAll()
    }
}
