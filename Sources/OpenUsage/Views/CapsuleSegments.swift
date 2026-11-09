import SwiftUI

/// A row of choices on a capsule track, with a white thumb that slides to the chosen one.
struct CapsuleSegments<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var height: CGFloat = 28
    var fontSize: CGFloat = 13
    var segmentWidth: CGFloat?
    /// Picks a segment as the mouse goes down and moves the thumb there at once, like a native tab.
    var selectsOnPress = false

    @Environment(\.reduceAnimations) private var reduceAnimations
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { segment($0.value, label: $0.label) }
        }
        .padding(2)
        .frame(height: height)
        .background(Theme.controlFill, in: Capsule())
        .animation(reduceAnimations || selectsOnPress ? nil : Motion.navigation, value: selection)
    }

    private func segment(_ value: Value, label: String) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            Text(label)
                .font(.system(size: fontSize, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: segmentWidth)
                .frame(maxWidth: segmentWidth == nil ? .infinity : nil, maxHeight: .infinity)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.segmentThumb)
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if selectsOnPress, !isSelected { selection = value }
        })
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
