import SwiftUI

/// The scroll container shared by the popover's three full-height screens (dashboard, Customize,
/// Settings). Each one fills the region the pinned footer leaves and keeps the native scroll edge
/// effect alive while hiding the scrollbar.
///
/// The scroll edge effect (the blur as content passes under the `safeAreaBar`) needs the scroll view
/// to keep a vertical scroller, so indicators are not hidden the SwiftUI way (that removes the
/// scroller and kills the effect). `invisibleOverlayScroller()` instead keeps the overlay scroller
/// (which reserves no gutter) and just makes it invisible: effect intact, no visible bar.
///
/// Screen-specific modifiers — scroll position, edge-effect style, `onAppear`, reorder-frame
/// preferences — are applied by the caller on the returned view, since those differ per screen.
/// (Self-measuring was removed when the panel became a fixed, user-resizable size: the screens no
/// longer report their content height since nothing fits the popover to it anymore.)
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
