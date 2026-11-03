import SwiftUI

extension View {
    /// Fills a row's placeholder shapes with quiet grey and sweeps a slow shimmer across them, which Reduce Motion stops.
    func skeleton() -> some View {
        foregroundStyle(Theme.skeleton).modifier(Shimmer())
    }
}

private struct Shimmer: ViewModifier {
    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var progress: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceAnimations {
            content
        } else {
            content
                .mask {
                    GeometryReader { proxy in
                        // Three widths wide with a dim band in the middle, which starts and ends off the row.
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.35),
                                .init(color: .black.opacity(0.4), location: 0.5),
                                .init(color: .black, location: 0.65),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 3, height: proxy.size.height)
                        .offset(x: proxy.size.width * (2 * progress - 2))
                    }
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { progress = 1 }
                }
        }
    }
}
