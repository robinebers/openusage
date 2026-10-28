import SwiftUI
import os

/// Built as a `GeometryEffect` (like `DenyShakeEffect`) rather than a plain `ViewModifier`: a custom
/// `ViewModifier` that implements `body` is inferred `@MainActor` (because `ViewModifier.body` is), which
/// would make `animatableData` `@MainActor` and violate `Animatable`'s `nonisolated` requirement.
/// `GeometryEffect` supplies its own `body`, so the struct stays nonisolated and the `Animatable`
/// conformance is clean; the forwarding goes through the `nonisolated` `PanelHeightBridge`. The effect
/// itself is an identity transform — we only want its per-frame `animatableData` hook, no visual change.
struct PanelHeightModifier: GeometryEffect {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set {
            height = newValue
            PanelHeightBridge.push(newValue)
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        PanelHeightBridge.push(height)
        return ProjectionTransform()
    }
}

/// Forwards interpolated heights from the (nonisolated) `Animatable` setter to the `@MainActor` panel
/// bridge. The hop onto the main queue is MANDATORY and lives here: the setter fires from inside
/// SwiftUI's update pass, and `applyHeight`'s `setFrame` re-enters AppKit layout on the
/// constraint-pinned host — running it synchronously would trip `_NSDetectedLayoutRecursion`. The hop
/// lands it just after the pass unwinds, still within the same display interval. Bursts are coalesced
/// to the newest pending height so the panel never replays stale animation frames after SwiftUI has
/// already moved on. SwiftUI interpolates on the main thread, so `assumeIsolated` is the right bridge
/// to the `@MainActor` closure.
enum PanelHeightBridge {
    private struct State {
        var generation = 0
        var pendingHeight: CGFloat?
        var isScheduled = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    nonisolated static func invalidate() {
        state.withLock {
            $0.generation += 1
            $0.pendingHeight = nil
            $0.isScheduled = false
        }
    }

    nonisolated static func push(_ height: CGFloat) {
        guard height > 0 else { return }
        let (scheduled, shouldSchedule) = state.withLock { state in
            state.pendingHeight = height
            let scheduled = state.generation
            guard !state.isScheduled else { return (scheduled, false) }
            state.isScheduled = true
            return (scheduled, true)
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            let height = state.withLock { state -> CGFloat? in
                guard state.generation == scheduled else { return nil }
                let height = state.pendingHeight
                state.pendingHeight = nil
                state.isScheduled = false
                return height
            }
            guard let height else { return }
            MainActor.assumeIsolated {
                MenuBarPopover.applyHeight?(height)
            }
        }
    }
}

extension View {
    func drivesPanelHeight(_ height: CGFloat) -> some View {
        modifier(PanelHeightModifier(height: height))
    }
}
