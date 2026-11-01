import SwiftUI

/// The bars above and below sit straight on the panel. From macOS 26 the system's scroll edge effect
/// blurs and fades content under them; before it, content simply fades out.
struct PopoverScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let scrollView = ScrollView(.vertical) {
            content
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)

        if #available(macOS 26, *) {
            scrollView.panelScrollEdge()
        } else {
            scrollView.mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: DashboardContentView.barGap)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: DashboardContentView.barGap)
                }
            }
        }
    }
}

extension View {
    @ViewBuilder
    func panelScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            self
        }
    }

    /// A bar over the panel's scrolling content, which from macOS 26 takes the system's edge effect.
    @ViewBuilder
    func panelBar(edge: VerticalEdge, @ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: 0, content: content)
        }
    }
}
