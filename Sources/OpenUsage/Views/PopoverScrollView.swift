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
        .mask {
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
