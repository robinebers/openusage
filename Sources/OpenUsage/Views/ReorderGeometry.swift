import SwiftUI

struct ReorderLift {
    let id: String
    let preview: AnyView
    let sourceFrame: CGRect
    let touchOffset: CGPoint
    var location: CGPoint

    /// The one place a lift is built from a drag value. Every reorder site (dashboard/Accounts ×
    /// provider/metric) differs only in the `preview`; the frame lookup and touch-offset math are
    /// identical, so they live here once. Returns `nil` when the dragged row has no recorded frame.
    static func make(
        id: String,
        preview: AnyView,
        value: DragGesture.Value,
        frames: [String: CGRect]
    ) -> ReorderLift? {
        guard let sourceFrame = frames[id] else { return nil }
        return ReorderLift(
            id: id,
            preview: preview,
            sourceFrame: sourceFrame,
            touchOffset: CGPoint(
                x: value.startLocation.x - sourceFrame.minX,
                y: value.startLocation.y - sourceFrame.minY
            ),
            location: value.location
        )
    }
}

/// The previews are deliberately the same views the live screens render (shared row/card builders), so a
/// lifted row matches the row it came from.
struct ReorderLiftPreview: View {
    let lift: ReorderLift

    var body: some View {
        lift.preview
            .frame(width: lift.sourceFrame.width)
            .scaleEffect(1.025)
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
            .position(
                x: lift.location.x - lift.touchOffset.x + lift.sourceFrame.width / 2,
                y: lift.location.y - lift.touchOffset.y + lift.sourceFrame.height / 2
            )
            .animation(.none, value: lift.location)
            .allowsHitTesting(false)
    }
}

/// Lightweight in-view geometry used for reordering inside the menu-bar popover.
///
/// This deliberately avoids SwiftUI's pasteboard-backed `.draggable` / `.dropDestination` APIs, which are
/// unreliable in this popover. A plain `DragGesture` stays inside the SwiftUI view tree: we record row frames,
/// compare the pointer location to those frames, and then mutate `LayoutStore` directly.
struct ReorderFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// Keeps continuously changing scroll geometry out of SwiftUI state. The preference updates on every
/// scroll frame; storing it in `@State` invalidates the whole widget list even though only drag gestures
/// need the latest values.
final class ReorderFrameStore {
    var frames: [String: CGRect] = [:]
}

extension View {
    func reorderFrame(id: String, in coordinateSpace: CoordinateSpace) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReorderFramePreferenceKey.self,
                    value: [id: proxy.frame(in: coordinateSpace)]
                )
            }
        )
    }
}

/// The shared drag-to-reorder gesture used by both the dashboard list and the Accounts screen, for both
/// provider headers and metric rows. The gesture body (lift tracking, target hit-testing, spring + haptic)
/// lives here once; each caller supplies only what differs: the active-row binding, the lift builder, the
/// current ordered ids, and the reorder action.
@MainActor
func reorderDragGesture(
    id: String,
    coordinateSpaceName: String,
    frameStore: ReorderFrameStore,
    active: Binding<String?>,
    lift: Binding<ReorderLift?>,
    makeLift: @escaping (DragGesture.Value) -> ReorderLift?,
    orderedIDs: @escaping () -> [String],
    reorder: @escaping (_ target: String) -> Bool
) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpaceName))
        .onChanged { value in
            active.wrappedValue = id
            if lift.wrappedValue?.id != id, let newLift = makeLift(value) {
                lift.wrappedValue = newLift
            }
            lift.wrappedValue?.location = value.location
            guard let target = reorderTarget(
                at: value.location,
                in: frameStore.frames,
                excluding: id,
                orderedIDs: orderedIDs()
            ) else { return }
            var moved = false
            withAnimation(Motion.spring) {
                moved = reorder(target)
            }
            if moved { Haptics.snap() }
        }
        .onEnded { _ in
            active.wrappedValue = nil
            lift.wrappedValue = nil
        }
}

func reorderTarget(
    at location: CGPoint,
    in frames: [String: CGRect],
    excluding draggedID: String,
    orderedIDs: [String]
) -> String? {
    guard let from = orderedIDs.firstIndex(of: draggedID) else { return nil }
    let crossingThreshold = 0.20

    for id in orderedIDs where id != draggedID {
        guard let to = orderedIDs.firstIndex(of: id),
              let frame = frames[id]
        else { continue }

        guard frame.insetBy(dx: 0, dy: -2).contains(location) else { continue }

        // Reorder only after crossing partway into the target row. This avoids the jumpy feel where a row moves
        // as soon as the pointer barely enters a neighbor, while still feeling less delayed than the midpoint.
        if to > from {
            return location.y >= frame.minY + frame.height * crossingThreshold ? id : nil
        } else {
            return location.y <= frame.maxY - frame.height * crossingThreshold ? id : nil
        }
    }

    return nil
}
