import AppKit
import SwiftUI

/// A hover tooltip that behaves like the native `.help()` tooltip but appears after a delay we control
/// (the native one waits ~1.5-2s on the first hover, with no public API to shorten) and is anchored
/// to the hovered item: centered on it horizontally, just above its top edge.
///
/// It's drawn in its own borderless, non-activating, click-through `NSPanel` — not a SwiftUI overlay.
/// A SwiftUI overlay lives inside the popover's window and is clipped to it (and to the dashboard's
/// scroll view), so it can't float freely the way a tooltip must. The panel sits one level above the
/// status-item popover (which is `.popUpMenu`): `orderFrontRegardless()` only orders the panel to the
/// front of its own level, so at the same level a later click that re-fronts the popover would bury the
/// tooltip behind it — a strictly higher level keeps it above regardless of front-ordering.
/// It never becomes key and never activates the app (shown via `orderFrontRegardless()`), which is the
/// documented carve-out that keeps it from dismissing the transient popover; `ignoresMouseEvents` makes
/// it click-through so it can't steal the hover that spawned it. The popover closing doesn't move the
/// cursor or tear down the (surviving) SwiftUI tree, so `HoverTooltips.dismissAll()` clears any live
/// tooltip from the status-item controller's hide path.

extension View {
    func hoverTooltip(_ text: String?) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }
}

@MainActor
private final class TooltipAnchor {
    weak var view: NSView?
    nonisolated init() {}

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct TooltipAnchorView: NSViewRepresentable {
    let anchor: TooltipAnchor

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String?
    @State private var id = UUID()
    @State private var anchor = TooltipAnchor()
    @State private var isHovering = false

    private var resolved: String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    func body(content: Content) -> some View {
        content
            .background { if resolved != nil { TooltipAnchorView(anchor: anchor) } }
            .accessibilityHint(resolved ?? "")
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    syncPresenter()
                case .ended:
                    isHovering = false
                    TooltipPresenter.shared.exit(id: id)
                }
            }
            .onChange(of: resolved) { syncPresenter() }
            .onDisappear {
                isHovering = false
                TooltipPresenter.shared.exit(id: id)
            }
    }

    private func syncPresenter() {
        guard isHovering else { return }
        if let resolved {
            TooltipPresenter.shared.enter(id: id, text: resolved, anchor: anchor)
        } else {
            TooltipPresenter.shared.exit(id: id)
        }
    }
}

@MainActor
private final class TooltipPresenter {
    static let shared = TooltipPresenter()

    private struct Target {
        let text: String
        let anchor: TooltipAnchor
    }

    private var active: [UUID: Target] = [:]
    private var shownID: UUID?
    private(set) var shownText: String?
    private var pendingID: UUID?
    private var revealTask: Task<Void, Never>?

    private let revealDelay: Duration = .milliseconds(400)

    private let anchorGap: CGFloat = 10

    private let maxTooltipWidth: CGFloat = 280

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let panel = NonKeyPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],   // set once at init; toggling later desyncs activation
        backing: .buffered,
        defer: false
    )

    private init() {
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.contentView = host
    }

    func enter(id: UUID, text: String, anchor: TooltipAnchor) {
        active[id] = Target(text: text, anchor: anchor)
        refresh()
    }

    func exit(id: UUID) {
        guard active[id] != nil else { return }
        active[id] = nil
        refresh()
    }

    /// Clear everything. Called when the popover closes: its SwiftUI tree (and our hover state) survives
    /// `orderOut`, so no `.ended`/`.onDisappear` fires for a target the cursor was resting on, and a
    /// shown tooltip would otherwise orphan on screen with a pending reveal possibly firing afterward.
    func dismissAll() {
        active.removeAll()
        cancelPending()
        hide()
    }

    private func refresh() {
        guard let top = active.first else {
            cancelPending()
            hide()
            return
        }
        if shownID == top.key {
            if shownText != top.value.text {
                present(top.value)
                shownText = top.value.text
            }
            return
        }
        if shownID != nil {
            hide()
        }
        if pendingID == top.key { return }
        cancelPending()
        pendingID = top.key
        let target = top.value
        let id = top.key
        let delay = revealDelay
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.present(target)
            self.shownID = id
            self.shownText = target.text
            self.pendingID = nil
            self.revealTask = nil
        }
    }

    private func cancelPending() {
        revealTask?.cancel()
        revealTask = nil
        pendingID = nil
    }

    private func hide() {
        shownID = nil
        shownText = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func present(_ target: Target) {
        let size = measuredSize(for: target)
        panel.setContentSize(size)
        let cursor = NSEvent.mouseLocation
        let anchorRect = target.anchor.screenRect
            ?? NSRect(x: cursor.x, y: cursor.y, width: 0, height: 0)
        panel.setFrameOrigin(origin(for: size, anchor: anchorRect))
        panel.orderFrontRegardless()
    }

    /// Lays the bubble out at its natural single-line size, then — only when that would run wider than
    /// `maxTooltipWidth` — re-lays it wrapped, so a long tooltip breaks onto multiple lines instead of
    /// stretching off-screen while short ones keep their snug single-line size. Wrapped text is
    /// laid out at the narrowest width that still fits the same number of lines as the max-width layout
    /// (found by binary search on the measured height): lines come out roughly equal length and a lone
    /// orphan word can't hang on the last line — the closest SwiftUI gets to CSS `text-wrap: pretty`
    /// (there's no public `Text` API for it). A handful of extra layout passes, only at reveal time.
    /// Leaves `host.rootView` holding whichever bubble it settled on, which is the one shown.
    private func measuredSize(for target: Target) -> CGSize {
        func fit(maxTextWidth: CGFloat?) -> CGSize {
            host.rootView = AnyView(TooltipBubble(text: target.text, maxTextWidth: maxTextWidth))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let natural = fit(maxTextWidth: nil)
        guard natural.width > maxTooltipWidth else { return natural }
        let maxTextWidth = maxTooltipWidth - 2 * TooltipBubble.horizontalPadding
        let wrapped = fit(maxTextWidth: maxTextWidth)
        var tooNarrow: CGFloat = 0
        var fits = maxTextWidth
        while fits - tooNarrow > 1 {
            let mid = (tooNarrow + fits) / 2
            if fit(maxTextWidth: mid).height > wrapped.height {
                tooNarrow = mid
            } else {
                fits = mid
            }
        }
        return fit(maxTextWidth: fits.rounded(.up))
    }

    private func origin(for size: CGSize, anchor: NSRect) -> NSPoint {
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + anchorGap
        // The `contains` leg matters for the cursor fallback's zero-size anchor: an empty rect
        // intersects nothing, so without it clamping would fall back to `NSScreen.main` instead of
        // the screen under the cursor.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) || $0.frame.contains(anchor.origin) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = max(visible.minX, min(x, visible.maxX - size.width))
            if y + size.height > visible.maxY {
                y = anchor.minY - anchorGap - size.height
            }
            y = max(y, visible.minY)
        }
        return NSPoint(x: x, y: y)
    }

}

@MainActor
enum HoverTooltips {
    static func dismissAll() { TooltipPresenter.shared.dismissAll() }
    static var visibleText: String? { TooltipPresenter.shared.shownText }
}

private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct TooltipBubble: View {
    let text: String
    let maxTextWidth: CGFloat?

    static let horizontalPadding: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        label
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 5)
            .background { shape.fill(Color(nsColor: .windowBackgroundColor)) }
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
    }

    @ViewBuilder
    private var label: some View {
        let content = Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
        if let maxTextWidth {
            content.frame(width: maxTextWidth, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content.fixedSize()
        }
    }
}
