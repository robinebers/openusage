import SwiftUI

/// An in-app replacement for SwiftUI's `.help()` tooltip. The native tooltip has a long,
/// system-controlled first-hover delay (~1.5-2s before the first tooltip in a window appears; it
/// reshows later ones almost instantly) that no public API shortens, so the row's exact figures felt
/// slow to reveal on the first hover. This shows a styled bubble after a short, fixed delay we own.
///
/// Two pieces: `.hoverTooltip(_:)` on a hover target reports its text and frame, and a single
/// `.hoverTooltipContainer()` at the popover root draws the bubble. The bubble is drawn at the root,
/// not inside the hovered view, so it escapes the dashboard/settings/customize scroll views — those
/// clip their content, so an in-row bubble would be cut off near a scroll edge. The target publishes
/// its text and bounds up the tree via an anchor preference; the container resolves that anchor in its
/// own geometry, places the bubble just below the target (flipping above when it would overflow the
/// bottom), and clamps it inside the popover.

/// The active tooltip's text, an anchor on the hovered view's frame, and its nesting depth. A hover
/// over a nested control sits inside both the child and its container, so both publish a request after
/// the delay; the depth lets the more specific (deeper) one win.
private struct TooltipRequest {
    let text: String
    let anchor: Anchor<CGRect>
    let depth: Int
}

private struct TooltipRequestKey: PreferenceKey {
    static let defaultValue: TooltipRequest? = nil
    static func reduce(value: inout TooltipRequest?, nextValue: () -> TooltipRequest?) {
        // Keep the deepest live request so a nested control's tooltip beats its container's (the ⓘ note
        // over the row figures, or "Clear Shortcut" over the shortcut field) regardless of preference
        // traversal order. Targets that aren't showing contribute nil and drop out.
        guard let next = nextValue() else { return }
        guard let current = value else { value = next; return }
        if next.depth > current.depth { value = next }
    }
}

/// Nesting depth of a `.hoverTooltip` target. Each target bumps it for its descendants, so a child's
/// request outranks its container's in `TooltipRequestKey.reduce`.
private struct TooltipDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

private extension EnvironmentValues {
    var tooltipDepth: Int {
        get { self[TooltipDepthKey.self] }
        set { self[TooltipDepthKey.self] = newValue }
    }
}

extension View {
    /// Shows `text` in a custom hover tooltip after a short delay. `nil` or empty shows nothing, so the
    /// many `someTooltip ?? ""` call sites keep their "no tooltip when blank" behavior. The text is also
    /// exposed as an accessibility hint — the part `.help()` contributed to VoiceOver.
    func hoverTooltip(_ text: String?) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }

    /// Draws the hover tooltip for any `.hoverTooltip(_:)` target beneath this point. Apply once, at the
    /// popover root, above the scroll views so the bubble can extend past their clipped bounds.
    func hoverTooltipContainer() -> some View {
        overlayPreferenceValue(TooltipRequestKey.self) { request in
            GeometryReader { proxy in
                if let request {
                    TooltipBubble(text: request.text, target: proxy[request.anchor], bounds: proxy.size)
                }
            }
            // Never intercept the hover or clicks of the rows beneath, or the bubble would steal the
            // hover that spawned it and flicker.
            .allowsHitTesting(false)
        }
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String?
    @Environment(\.tooltipDepth) private var depth
    @State private var isShowing = false
    @State private var revealTask: Task<Void, Never>?

    /// Delay before the bubble appears. Short enough to feel responsive on the first hover (the native
    /// tooltip's slow first appearance is the whole reason this exists), long enough that brushing the
    /// cursor across rows doesn't flash bubbles.
    private static let revealDelay: Duration = .milliseconds(350)

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
            .onHover { inside in
                guard resolved != nil else { return }
                if inside { scheduleReveal() } else { cancelReveal() }
            }
            .onDisappear { cancelReveal() }
            .anchorPreference(key: TooltipRequestKey.self, value: .bounds) { anchor in
                guard isShowing, let resolved else { return nil }
                return TooltipRequest(text: resolved, anchor: anchor, depth: depth)
            }
    }

    private func scheduleReveal() {
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: Self.revealDelay)
            guard !Task.isCancelled else { return }
            isShowing = true
        }
    }

    private func cancelReveal() {
        revealTask?.cancel()
        revealTask = nil
        isShowing = false
    }
}

/// The tooltip bubble, positioned in the container's coordinate space. Sizing hugs short text on one
/// line yet wraps long copy at a cap — neither a plain `frame(maxWidth:)` (always fills to the cap)
/// nor `fixedSize` (never wraps) gives that alone, so a hidden single-line probe measures the natural
/// width and the visible label is framed to `min(natural, cap)`.
private struct TooltipBubble: View {
    let text: String
    let target: CGRect
    let bounds: CGSize
    @Environment(\.reduceTransparencyEffective) private var reduceTransparency
    @State private var idealTextWidth: CGFloat = 0
    @State private var bubbleSize: CGSize = .zero

    private static let font = Font.system(size: 12)
    private static let hPadding: CGFloat = 7
    private static let vPadding: CGFloat = 4
    private static let cornerRadius: CGFloat = 6
    /// Vertical gap between the target and the bubble.
    private static let gap: CGFloat = 4
    /// Keep-clear inset from the popover edges.
    private static let margin: CGFloat = 8
    private static let maxBubbleWidth: CGFloat = 240

    private var maxTextWidth: CGFloat {
        max(40, min(Self.maxBubbleWidth, bounds.width - 2 * Self.margin) - 2 * Self.hPadding)
    }

    private var textWidth: CGFloat {
        min(idealTextWidth, maxTextWidth)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Probe: single-line natural width, never drawn. Lets the visible label hug short text
            // yet wrap long copy at the cap.
            Text(text)
                .font(Self.font)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { idealTextWidth = $0 }

            if idealTextWidth > 0 {
                bubble
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
                    .offset(x: originX, y: originY)
                    // Hidden until measured so the bubble never flashes at the origin before it's placed.
                    .opacity(bubbleSize == .zero ? 0 : 1)
                    .animation(.easeOut(duration: 0.1), value: bubbleSize == .zero)
            }
        }
    }

    private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return Text(text)
            .font(Self.font)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            // +1 guards against a rounding-induced wrap when the label is framed to its own ideal width.
            .frame(width: ceil(textWidth) + 1, alignment: .leading)
            .padding(.horizontal, Self.hPadding)
            .padding(.vertical, Self.vPadding)
            .background {
                // Solid in the reduced-transparency form (matching the popover's own solid surface),
                // a frosted material otherwise so the bubble reads like a native tooltip on glass.
                if reduceTransparency {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }

    /// Leading-aligned to the target, clamped so the bubble never pokes past either side edge.
    private var originX: CGFloat {
        let maxX = max(Self.margin, bounds.width - bubbleSize.width - Self.margin)
        return min(max(target.minX, Self.margin), maxX)
    }

    /// Below the target by default; flips above when the bubble would overflow the bottom and there's
    /// room up top, otherwise clamps below into bounds.
    private var originY: CGFloat {
        let below = target.maxY + Self.gap
        let above = target.minY - Self.gap - bubbleSize.height
        if below + bubbleSize.height <= bounds.height - Self.margin { return below }
        if above >= Self.margin { return above }
        return max(Self.margin, min(below, bounds.height - bubbleSize.height - Self.margin))
    }
}
