import AppKit
import SwiftUI

extension View {
    /// SwiftUI does not expose the backing `NSPopover.animates` flag, so reduced motion crosses the
    /// AppKit boundary only for presentation. The normal path stays on SwiftUI's standard popover.
    func motionAwareHoverPopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        reduceAnimations: Bool,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) -> some View {
        modifier(MotionAwareHoverPopoverModifier(
            isPresented: isPresented,
            reduceAnimations: reduceAnimations,
            popoverContent: content
        ))
    }
}

private struct MotionAwareHoverPopoverModifier<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let reduceAnimations: Bool
    @ViewBuilder let popoverContent: () -> PopoverContent

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceAnimations {
            content.background {
                ReducedMotionPopoverPresenter(
                    isPresented: $isPresented,
                    reduceAnimations: reduceAnimations,
                    popoverContent: popoverContent
                )
            }
        } else {
            content.popover(isPresented: $isPresented, arrowEdge: .top, content: popoverContent)
        }
    }
}

/// An invisible anchor that owns the one AppKit presentation detail SwiftUI does not expose:
/// `NSPopover.animates`. SwiftUI remains the source of truth through `isPresented`.
private struct ReducedMotionPopoverPresenter<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let reduceAnimations: Bool
    @ViewBuilder let popoverContent: () -> PopoverContent

    func makeCoordinator() -> ReducedMotionPopoverController {
        ReducedMotionPopoverController(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> PopoverAnchorView {
        let view = PopoverAnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.synchronize(with: view)
        }
        return view
    }

    func updateNSView(_ nsView: PopoverAnchorView, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.update(
            content: AnyView(popoverContent()),
            reduceAnimations: reduceAnimations,
            anchor: nsView
        )
    }

    static func dismantleNSView(_ nsView: PopoverAnchorView, coordinator: ReducedMotionPopoverController) {
        nsView.onWindowChange = nil
        coordinator.dismissWithoutUpdatingBinding()
    }

    @MainActor
    final class PopoverAnchorView: NSView {
        var onWindowChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// Owns the AppKit objects and delegate lifecycle outside the generic SwiftUI representable.
@MainActor
final class ReducedMotionPopoverController: NSObject, NSPopoverDelegate {
    var isPresented: Binding<Bool>
    let popover: NSPopover

    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var ignoreNextClose = false

    init(isPresented: Binding<Bool>) {
        self.isPresented = isPresented
        self.popover = NSPopover()
        super.init()
        popover.animates = false
        popover.behavior = .transient
        popover.contentViewController = host
        popover.delegate = self
    }

    func update(content: AnyView, reduceAnimations: Bool, anchor: NSView) {
        host.rootView = AnyView(content.animationReduction(reduceAnimations))
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        if size.width > 0, size.height > 0 {
            popover.contentSize = size
        }
        synchronize(with: anchor)
    }

    func synchronize(with anchor: NSView) {
        guard isPresented.wrappedValue else {
            if popover.isShown { popover.performClose(nil) }
            return
        }
        guard anchor.window != nil, !popover.isShown else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func dismissWithoutUpdatingBinding() {
        guard popover.isShown else { return }
        ignoreNextClose = true
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        if ignoreNextClose {
            ignoreNextClose = false
            return
        }
        if isPresented.wrappedValue {
            isPresented.wrappedValue = false
        }
    }
}
