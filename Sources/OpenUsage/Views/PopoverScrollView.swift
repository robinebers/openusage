import SwiftUI

/// The bars above and below sit straight on the panel, so scrolled content fades out before it
/// reaches them.
struct PopoverScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .panelScrollEdge()
    }
}

extension View {
    /// Fades scrolled content out at the panel's bars, in place of the system's scroll edge effect,
    /// which from macOS 26 would draw a glass backdrop behind them.
    @ViewBuilder
    func panelScrollEdge() -> some View {
        let faded = mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: DashboardContentView.barGap)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: DashboardContentView.barGap)
            }
        }
        if #available(macOS 26, *) {
            faded.scrollEdgeEffectHidden(true, for: .vertical)
        } else {
            faded
        }
    }
}
