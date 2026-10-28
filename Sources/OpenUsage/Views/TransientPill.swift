import SwiftUI

struct TransientPill: View {
    let systemImage: String
    let text: String
    let tint: AnyShapeStyle
    let trigger: Int
    var showsShadow = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(showsShadow ? 0.12 : 0), radius: 6, y: 2)
        .id(trigger)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}
