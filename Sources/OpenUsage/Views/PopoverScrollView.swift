import SwiftUI

/// The scroll edge effect (the blur as content passes under the `safeAreaBar`) needs the scroll view
/// to keep a vertical scroller, so indicators are not hidden the SwiftUI way (that removes the
/// scroller and kills the effect). `invisibleOverlayScroller()` instead keeps the overlay scroller
/// (which reserves no gutter) and just makes it invisible: effect intact, no visible bar.
struct PopoverScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .invisibleOverlayScroller()
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

