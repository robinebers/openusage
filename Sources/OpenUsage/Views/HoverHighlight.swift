import SwiftUI

extension View {
    /// The app's hover chip: a quaternary fill that fades in around interactive text without moving it.
    func hoverHighlight(_ isLit: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .padding(.horizontal, -6)
                .padding(.vertical, -2)
                .opacity(isLit ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.12), value: isLit)
    }
}
