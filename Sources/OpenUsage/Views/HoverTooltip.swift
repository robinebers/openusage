import AppKit
import SwiftUI

/// A hover tooltip that behaves like the native `.help()` tooltip but appears after a delay we control
/// (the native one waits ~1.5-2s on the first hover, with no public API to shorten) and is placed
/// above the cursor, centered on it.
///
/// It's drawn in its own borderless, non-activating, click-through `NSPanel` — not a SwiftUI overlay.
/// A SwiftUI overlay lives inside the popover's window and is clipped to it (and to the dashboard's
/// scroll view), so it can't float freely the way a tooltip must. The panel sits at `.popUpMenu` — the
/// same level as the status-item popover — so it shows over the popover by being ordered in front, not
/// by a higher level. It never becomes key and never activates the app (shown via
/// `orderFrontRegardless()`), which is the documented carve-out that keeps it from dismissing the
/// transient popover; `ignoresMouseEvents` makes it click-through so it can't steal the hover that
/// spawned it. The popover closing doesn't move the cursor or tear down the (surviving) SwiftUI tree,
/// so `HoverTooltips.dismissAll()` clears any live tooltip from the status-item controller's hide path.
///
/// Usage: `.hoverTooltip(_:)` on any hover target. No root container is needed — the panel is a
/// separate window owned by `TooltipPresenter`.

extension View {
    /// Shows `text` in a hover tooltip after a short delay, positioned above the cursor. `nil` or empty
    /// shows nothing, so the many `someTooltip ?? ""` call sites keep their "no tooltip when blank"
    /// behavior. The text is also exposed as an accessibility hint — the part `.help()` gave VoiceOver.
    func hoverTooltip(_ text: String?) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }
}

/// Per-target nesting depth so a nested control's tooltip beats its container's when a hover sits in
/// both (e.g. the clear button inside the Settings shortcut field). Each target bumps it for its
/// descendants; `TooltipPresenter` shows the deepest active one.
private struct TooltipDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

private extension EnvironmentValues {
    var tooltipDepth: Int {
        get { self[TooltipDepthKey.self] }
        set { self[TooltipDepthKey.self] = newValue }
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String?
    @Environment(\.tooltipDepth) private var depth
    @Environment(\.reduceTransparencyEffective) private var reduceTransparency
    /// Stable per-target identity, so the presenter can track which targets are currently hovered and
    /// drop this one on exit.
    @State private var id = UUID()
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
            // Descendants nest one level deeper, so a child target outranks this one when a hover sits
            // inside both.
            .environment(\.tooltipDepth, depth + 1)
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
            TooltipPresenter.shared.enter(id: id, text: resolved, depth: depth,
                                          reduceTransparency: reduceTransparency)
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
        let depth: Int
        let reduceTransparency: Bool
    }

    /// Targets the cursor is currently inside. More than one only while a hover sits in both a child
    /// and its container; the deepest wins.
    private var active: [UUID: Target] = [:]
    /// The target currently on screen (and its text, to detect a live text change), and the one a
    /// pending reveal is scheduled for.
    private var shownID: UUID?
    private var shownText: String?
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
    /// every one of them pairs its long first-reveal delay with an instant reshow for neighbours, and
    /// that reshow grouping is precisely the quick mode we removed because it caused the sweep cascade.
    /// Without reshow, every hover (including a deliberate row-by-row read) pays this delay in full, so
    /// the value belongs at the responsive end of the intent window, not the long end. 300ms sits at the
    /// floor of that window and fires a little too readily on a slow drag across rows. If deliberate
    /// neighbour-to-neighbour reading ever feels laggy, raise this to 500ms before reintroducing any
    /// reshow shortcut, since a tuned reshow risks reopening the original complaint.
    private let revealDelay: Duration = .milliseconds(400)

    /// Space above the cursor; the panel's bottom edge sits this far above the pointer.
    private let cursorGap: CGFloat = 10

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
        // host has an intrinsic size to report; the bubble is `.fixedSize()`, so that equals the size we
        // set and the host can't grow the panel out from under us.
        panel.isFloatingPanel = true
        panel.level = .popUpMenu                          // same level as the status-item popover; wins by being ordered front
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

    func enter(id: UUID, text: String, depth: Int, reduceTransparency: Bool) {
        active[id] = Target(text: text, depth: depth, reduceTransparency: reduceTransparency)
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

    /// Reconcile the panel with the deepest active target. Cheap and idempotent, so the per-pixel
    /// `onContinuousHover` calls mostly hit an early return.
    private func refresh() {
        guard let top = active.max(by: { $0.value.depth < $1.value.depth }) else {
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
        // A hovered descendant outranks the parent already on screen: hand off immediately, since the
        // dwell was already earned on the parent (e.g. the clear button inside the Settings shortcut
        // field). Reading `active[shownID]` ties this to the shown target still being hovered, so
        // "deeper" means a genuine parent→child handoff, not a stale depth comparison.
        if let shownID, let shown = active[shownID], top.value.depth > shown.depth {
            present(top.value)
            self.shownID = top.key
            shownText = top.value.text
            cancelPending()
            return
        }
        // Any other switch (a same-depth sibling or a shallower target) hides the current bubble and
        // makes the new target re-earn the full dwell, so sweeping across sibling labels while one is
        // up doesn't retarget the tooltip on every pass.
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
        host.rootView = AnyView(TooltipBubble(text: target.text, reduceTransparency: target.reduceTransparency))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, cursor: NSEvent.mouseLocation))
        panel.orderFrontRegardless()                   // show without activating the app or taking key
    }

    /// Above the cursor and centered on it, clamped to the cursor's screen; flips below the cursor when
    /// it would clip the top. All math in Cocoa screen coordinates (bottom-left origin, y grows up),
    /// matching `NSEvent.mouseLocation` and `NSScreen.visibleFrame`.
    private func origin(for size: CGSize, cursor: NSPoint) -> NSPoint {
        var x = cursor.x - size.width / 2
        var y = cursor.y + cursorGap
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Clamp leading edge into the visible frame. The `min` keeps the trailing edge in, the outer
            // `max` keeps the leading edge in even when the bubble is wider than the screen (it would
            // otherwise land off the left edge — a reversed-bounds clamp).
            x = max(visible.minX, min(x, visible.maxX - size.width))
            if y + size.height > visible.maxY {
                y = cursor.y - cursorGap - size.height
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
}

/// Never becomes key or main, so showing it can't pull focus and dismiss the transient popover.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The bubble drawn inside the panel: a frosted material on glass, a solid fill under Reduce
/// Transparency, with a hairline border. Sizes to its content (`fittingSize` drives the panel size);
/// the panel's window shadow supplies the drop shadow.
private struct TooltipBubble: View {
    let text: String
    let reduceTransparency: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
    }
}
