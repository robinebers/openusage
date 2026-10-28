import SwiftUI
import AppKit

extension View {
    /// Hides the scrollbar on the enclosing `NSScrollView` without losing the native scroll edge
    /// effect. Apply to content *inside* a `ScrollView`.
    ///
    /// On macOS Tahoe the scroll edge effect (the blur as content passes under a `safeAreaBar`) needs
    /// the scroll view to keep a vertical scroller — so hiding indicators the SwiftUI way
    /// (`.scrollIndicators(.hidden)`) removes the scroller and kills the effect with it.
    ///
    /// The scroll view already uses an *overlay* scroller (which floats and reserves no gutter), so the
    /// only thing left is to make that scroller invisible. We force overlay and set the existing
    /// scroller's `alphaValue` to 0. Crucially we do **not** replace `verticalScroller`: assigning a
    /// custom `NSScroller` flips the view to legacy style, which reserves a ~17pt gutter on the right.
    func invisibleOverlayScroller() -> some View {
        background(InvisibleOverlayScroller())
    }
}

/// Reaches the enclosing `NSScrollView` (this sits inside the scroll content, so `enclosingScrollView`
/// resolves) and makes its overlay scroller invisible. Re-applies when the system scroller style
/// changes — e.g. plugging in a mouse — since AppKit may recreate the scroller and reset its alpha.
private struct InvisibleOverlayScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerView { ScrollerView() }

    func updateNSView(_ nsView: ScrollerView, context: Context) {
        nsView.apply()
    }

    final class ScrollerView: NSView {
        private var styleObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let styleObserver {
                NotificationCenter.default.removeObserver(styleObserver)
                self.styleObserver = nil
            }
            guard window != nil else { return }
            apply()
            // `enclosingScrollView` may not be wired up until the current layout pass commits.
            DispatchQueue.main.async { [weak self] in self?.apply() }
            styleObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller?.alphaValue = 0
        }
    }
}
