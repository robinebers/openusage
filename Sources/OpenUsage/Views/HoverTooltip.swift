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
///
/// Usage: `.hoverTooltip(_:)` on any hover target. No root container is needed — the panel is a
/// separate window owned by `TooltipPresenter`.

extension View {
    /// Shows `text` in a hover tooltip after a short delay, anchored above the hovered item. `nil` or empty
    /// shows nothing, so the many `someTooltip ?? ""` call sites keep their "no tooltip when blank"
    /// behavior. The text is also exposed as an accessibility hint — the part `.help()` gave VoiceOver.
    func hoverTooltip(_ text: String?) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }
}

/// Weak handle to the hovered target's backing `NSView`. The presenter resolves it to a screen rect
/// lazily at show time (no continuous geometry publishing, and still correct if the popover moved).
@MainActor
private final class TooltipAnchor {
    weak var view: NSView?
    nonisolated init() {}

    /// The target's frame in Cocoa screen coordinates, or `nil` once the view is gone or windowless.
    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// Invisible background view whose only job is to hand its `NSView` (sized to the hover target by
/// `.background`) to the anchor. Hit-test transparent so it can never swallow the hover or clicks.
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
    /// Stable per-target identity, so the presenter can track which targets are currently hovered and
    /// drop this one on exit.
    @State private var id = UUID()
    /// Tracks the target's backing view so the presenter can anchor the bubble to the item itself.
    @State private var anchor = TooltipAnchor()
    /// Whether the cursor is currently inside this target, so `onChange(of: resolved)` knows whether to
    /// act when the text changes without a hover event firing.
    @State private var isHovering = false

    /// `nil` (no tooltip) for a missing or blank string, collapsing the two "absent" cases.
    private var resolved: String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    func body(content: Content) -> some View {
        content
            // The anchor exists only while there is something to anchor: a target with nothing to show
            // mounts no AppKit view, so a static row costs nothing and an off-screen render has no
            // placeholder to rasterize.
            .background { if resolved != nil { TooltipAnchorView(anchor: anchor) } }
            .accessibilityHint(resolved ?? "")
            // Continuous (not plain `onHover`) so the presenter always has the live hover state; it
            // reads the cursor itself at show time, so the reported location is unused here.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    syncPresenter()
                case .ended:
                    // Always exit, regardless of `resolved`: if the text went nil/empty while hovered,
                    // a guarded-out `.ended` would leave this target in the presenter and its tooltip
                    // would linger.
                    isHovering = false
                    TooltipPresenter.shared.exit(id: id)
                }
            }
            // Text can change while the cursor sits still (e.g. a meter tooltip refreshing to a no-tip
            // state on its 30s tick), with no hover event to react to — reconcile so the bubble updates
            // or clears.
            .onChange(of: resolved) { syncPresenter() }
            // A row can be torn down (scroll, screen switch, popover close) without an `.ended`, so
            // clear our entry here too or the panel could linger.
            .onDisappear {
                isHovering = false
                TooltipPresenter.shared.exit(id: id)
            }
    }

    /// Reflect the current hover state into the presenter: show this target's text while hovered, drop
    /// it when there's no text. A no-op when not hovered (so a text change off-hover does nothing).
    private func syncPresenter() {
        guard isHovering else { return }
        if let resolved {
            TooltipPresenter.shared.enter(id: id, text: resolved, anchor: anchor)
        } else {
            TooltipPresenter.shared.exit(id: id)
        }
    }
}

/// Owns the single reused tooltip panel and decides which hovered target is shown. Main-actor isolated:
/// every entry point is a SwiftUI hover callback (already on the main actor) and it only touches AppKit.
@MainActor
private final class TooltipPresenter {
    static let shared = TooltipPresenter()

    private struct Target {
        let text: String
        let anchor: TooltipAnchor
    }

    /// Targets the cursor is currently inside.
    private var active: [UUID: Target] = [:]
    /// The target currently on screen (and its text, to detect a live text change), and the one a
    /// pending reveal is scheduled for.
    private var shownID: UUID?
    private(set) var shownText: String?
    private var pendingID: UUID?
    private var revealTask: Task<Void, Never>?

    /// One consistent dwell before any new tooltip target shows. There's no fast-reshow "quick mode":
    /// sweeping the cursor across adjacent labels would otherwise flash a burst of tooltips, since once
    /// one is up every sibling it passes over would reveal near-instantly.
    ///
    /// 400ms is a deliberate value, not a guess. It's the overlap of the hover-intent windows in the
    /// research (Nielsen Norman Group puts reliable intent at 300-500ms of cursor stillness, the
    /// Müller-Tomfelde dwell study at 350-600ms) and sits on the Doherty threshold (~400ms), the line
    /// between feeling responsive and feeling slow. The longer 500-700ms defaults in Radix (700),
    /// Base UI (600), and Windows (500) are tempting for a dense list of targets like these rows, but
    /// every one of them pairs its long first-reveal delay with an instant reshow for neighbours, and a
    /// reshow cascades on a sweep across rows. Without reshow, every hover (including a deliberate
    /// row-by-row read) pays this delay in full, so the value belongs at the responsive end of the intent
    /// window, not the long end. 300ms sits at the floor of that window and fires a little too readily
    /// on a slow drag across rows.
    private let revealDelay: Duration = .milliseconds(400)

    /// Space between the bubble and the anchor: the panel's bottom edge sits this far above the
    /// hovered item's top edge (or below its bottom edge when flipped).
    private let anchorGap: CGFloat = 10

    /// Bubble width past which a tooltip wraps onto multiple lines instead of stretching ever wider.
    /// Sits comfortably under the 320pt popover so a wrapped tooltip never reads as a second panel.
    private let maxTooltipWidth: CGFloat = 280

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let panel = NonKeyPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],   // set once at init; toggling later desyncs activation
        backing: .buffered,
        defer: false
    )

    private init() {
        // Configure the panel up front (not lazily) so the hosting view is in a window from the start
        // and `fittingSize` measures correctly on the first show. Default sizing options stay on so the
        // host has an intrinsic size to report; the bubble reports a determinate size (`.fixedSize()`, or
        // a fixed width plus `fixedSize(vertical:)` once wrapped), so that equals the size we set and the
        // host can't grow the panel out from under us.
        panel.isFloatingPanel = true
        // One level above the status-item popover (also `.popUpMenu`): `orderFrontRegardless` only fronts
        // within a level, so matching it let a popover click bury the tooltip behind it. A strictly
        // higher level keeps it above. Still click-through + non-activating, and cleared on popover-close,
        // so it can't steal the hover, dismiss the transient popover, or orphan above a closed one.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true                   // click-through; never intercepts the hover
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                            // window shadow follows the bubble's rounded shape
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

    /// Reconcile the panel with the active target. Cheap and idempotent, so the per-pixel
    /// `onContinuousHover` calls mostly hit an early return.
    private func refresh() {
        guard let top = active.first else {
            cancelPending()
            hide()
            return
        }
        if shownID == top.key {                     // already the right target on screen
            if shownText != top.value.text {        // its text changed live — re-present, don't reposition away
                present(top.value)
                shownText = top.value.text
            }
            return
        }
        // Switching to another target hides the current bubble and makes the new target re-earn the
        // full dwell, so sweeping across sibling labels while one is up doesn't retarget the tooltip on
        // every pass.
        if shownID != nil {
            hide()
        }
        if pendingID == top.key { return }          // already scheduled for this target
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
        // Anchor to the hovered item; fall back to an empty rect at the cursor if the item's view is
        // already gone (defensive — the target exits on `.onDisappear`), which reproduces the old
        // cursor-centered placement.
        let cursor = NSEvent.mouseLocation
        let anchorRect = target.anchor.screenRect
            ?? NSRect(x: cursor.x, y: cursor.y, width: 0, height: 0)
        panel.setFrameOrigin(origin(for: size, anchor: anchorRect))
        panel.orderFrontRegardless()                   // show without activating the app or taking key
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
        // Height grows monotonically as the width shrinks, so binary-search (to 1pt) the smallest text
        // width whose layout is no taller than the max-width one.
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

    /// Above the anchor rect and centered on it, clamped to the anchor's screen; flips below the anchor
    /// when it would clip the top. All math in Cocoa screen coordinates (bottom-left origin, y grows
    /// up), matching `convertToScreen` and `NSScreen.visibleFrame`.
    private func origin(for size: CGSize, anchor: NSRect) -> NSPoint {
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + anchorGap
        // The `contains` leg matters for the cursor fallback's zero-size anchor: an empty rect
        // intersects nothing, so without it clamping would fall back to `NSScreen.main` instead of
        // the screen under the cursor.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) || $0.frame.contains(anchor.origin) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Clamp leading edge into the visible frame. The `min` keeps the trailing edge in, the outer
            // `max` keeps the leading edge in even when the bubble is wider than the screen (it would
            // otherwise land off the left edge — a reversed-bounds clamp).
            x = max(visible.minX, min(x, visible.maxX - size.width))
            if y + size.height > visible.maxY {
                y = anchor.minY - anchorGap - size.height
            }
            y = max(y, visible.minY)
        }
        return NSPoint(x: x, y: y)
    }

}

/// Seam for non-SwiftUI code (the status-item controller) to clear any visible tooltip when the popover
/// closes — `TooltipPresenter` is private.
@MainActor
enum HoverTooltips {
    static func dismissAll() { TooltipPresenter.shared.dismissAll() }
    /// The text of the tooltip on screen, or `nil` while none is: what a test reads off a hover.
    static var visibleText: String? { TooltipPresenter.shared.shownText }
}

/// Never becomes key or main, so showing it can't pull focus and dismiss the transient popover.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The bubble drawn inside the panel: a solid fill with a hairline border (the popover is opaque, so
/// the tooltip matches it rather than sampling glass). Sizes to its content (`fittingSize` drives the
/// panel size); the panel's window shadow supplies the drop shadow.
private struct TooltipBubble: View {
    let text: String
    /// When set, the text wraps to this width (long tooltips); `nil` keeps it a snug single line.
    let maxTextWidth: CGFloat?

    /// Inner horizontal padding around the text. `TooltipPresenter` subtracts it when deriving the
    /// text wrap width from the bubble's max width.
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
            // A fixed width (not `maxWidth`) so the wrapped height measures deterministically via
            // `fittingSize`; `fixedSize(vertical:)` pins the bubble to that ideal wrapped height.
            content.frame(width: maxTextWidth, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content.fixedSize()
        }
    }
}
