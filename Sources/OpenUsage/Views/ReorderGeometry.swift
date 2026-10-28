import SwiftUI

struct ReorderLift {
    let id: String
    let preview: AnyView
    let sourceFrame: CGRect
    let touchOffset: CGPoint
    var location: CGPoint

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

        if to > from {
            return location.y >= frame.minY + frame.height * crossingThreshold ? id : nil
        } else {
            return location.y <= frame.maxY - frame.height * crossingThreshold ? id : nil
        }
    }

    return nil
}
