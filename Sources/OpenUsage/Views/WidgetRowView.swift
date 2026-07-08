import AppKit
import SwiftUI

/// One metric as a row inside a provider's grouped list container. The provider icon is drawn once in the
/// section header (not per row), so a row shows only the metric. Two layouts:
/// - **Bounded** (`limit != nil`, meter row): a label line (right-aligned flame + run-out time when
///   projected to run out before reset, or "~3% spare" when cutting it close), then a full-width
///   capsule meter (color = pace verdict; in the amber state a tick splits the projected spare
///   cushion off the bar; hovering shows the verdict), then a primary text row ("50% left" ⟷ "Resets in 4d 17h").
///   Mirrors the original OpenUsage card.
/// - **Unbounded** (`limit == nil`, text-only row): **no bar**. Label on the left, a single right-aligned
///   descriptive line ("1,503 left") and an optional secondary line ("on-device estimate").
/// Rows size to their own content (variable height). Same `WidgetData` the menu bar uses — only layout differs.
struct WidgetRowView: View {
    let data: WidgetData
    /// Flips the global relative/absolute reset display. Supplied where the row has the data store
    /// (the dashboard list); `nil` in static contexts like the drag-reorder preview, where the reset
    /// label stays plain text.
    var onToggleResetDisplay: (() -> Void)?
    /// Flips the global Used/Left meter style — the headline's counterpart to the reset toggle.
    /// Same supply rules as `onToggleResetDisplay`.
    var onToggleMeterStyle: (() -> Void)?
    /// True when this text-only row sits directly under another text-only row. Rows don't know
    /// their neighbors — the list supplies it — and both densities use it to pull consecutive
    /// one-liners into a single cluster (Compact a step harder).
    var condensedTop: Bool = false

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular
    @State private var modelHover = HoverPopoverState()
    /// Party easter egg: fill meter bars with the party gradient instead of the severity color. Off by
    /// default everywhere else.
    @Environment(\.popoverPartyMode) private var partyMode

    /// Both row fonts come from the density setting: point sizes — not just padding — are what make
    /// Compact read as a denser mode. The sizes are explicit because semantic
    /// `.headline.weight(.regular)` does not match `.headline` on macOS, and `minimumScaleFactor`
    /// was shrinking only the trailing value.
    private var labelFont: Font {
        .system(size: density.labelPointSize, weight: .semibold)
    }

    private var supportingFont: Font {
        .system(size: density.supportingPointSize, weight: .regular)
    }

    var body: some View {
        // A row with a concrete reset date derives time-sensitive state (reset countdown, pace marker,
        // "Runs out in …") from the current clock, so it re-renders on a 30s tick — the cadence the
        // original app uses — instead of waiting for the next data refresh. TimelineView only schedules
        // ticks while the popover is actually visible. Rows without a reset date are static.
        Group {
            if data.resetsAt != nil || !data.expiriesAt.isEmpty {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    rowContent
                }
            } else {
                rowContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        // Bar rows are multi-line and earn breathing room; single-line text rows (Today / Yesterday /
        // Last 30 Days) stay tighter so consecutive ones read as a cluster, not evenly-spaced
        // full-height rows. This differentiation — not the fonts — is what kills the "jumpy" rhythm.
        // All values come from the global density setting; a text row pulls up against a preceding
        // text row (`condensedTop`) in both densities.
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }

    private var topPadding: CGFloat {
        if data.isBounded { return density.barRowPadding }
        return condensedTop ? density.condensedTextRowTopPadding : density.textRowPadding
    }

    private var bottomPadding: CGFloat {
        data.isBounded ? density.barRowPadding : density.textRowPadding
    }

    @ViewBuilder
    private var rowContent: some View {
        if data.isChart, data.hasData {
            // The sparkline owns its own label + bars; a chart with no real points falls through to the
            // unbounded "No data" row below (and so the descriptor's gallery sample never leaks here).
            UsageSparkline(data: data)
        } else if data.isBounded {
            boundedRow
        } else {
            unboundedRow
        }
    }

    /// Bounded: label (+ run-out warning) → meter → primary text row.
    /// The label, bar, and reading are one perceptual unit, so they sit on the tight step of the
    /// grid (`rowInnerSpacing`); the row's vertical padding provides the separation from
    /// neighboring rows.
    private var boundedRow: some View {
        let state = data.meterState()
        return VStack(alignment: .leading, spacing: density.rowInnerSpacing) {
            boundedLabelRow(state)
            meter(state)
            primaryTextRow
        }
    }

    /// Label with the pace warning right-aligned on the same line — one slot, escalating with the
    /// `MeterState`. Spent: a flame + "Limit reached",
    /// the terminal state that outranks any pace projection. Running out: a flame + projected
    /// run-out time, read as "Limit in 3h 45m" ⟷ "Limit today at 11:49 PM" (following the global
    /// countdown/exact mode) — clicking the time flips the global mode like the reset label. Close
    /// to limit: a quiet "~3% spare" — the cushion projected at reset. Healthy / level / no-data:
    /// nothing unless "always show pacing" surfaces projection on blue. Only the flame carries
    /// flame carries the severity color — tint on glass is reserved for the symbol while copy
    /// stays secondary like the row's other supporting text; the bar below carries the color.
    /// Hovering shows the pace projection at reset. The warning gets the space; the title truncates.
    private func boundedLabelRow(_ state: WidgetData.MeterState) -> some View {
        HStack(spacing: 6) {
            Text(data.title)
                .font(labelFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
            warning(state)
        }
    }

    /// The single escalating warning slot, switching exhaustively over the state so the copy can
    /// never contradict the bar. The flame cases share one builder; the amber and (always-show-pacing)
    /// blue cases are plain text.
    @ViewBuilder
    private func warning(_ state: WidgetData.MeterState) -> some View {
        switch state {
        case .spent:
            flameWarning(text: "Limit reached", state: state, accessibility: "Limit reached")
        case .runningOut(let eta, _):
            // `eta == nil` is the float-edge case: the flame stands alone (the projection lives in
            // the tooltip), rather than printing a misleading time. A shown time reads "Limit in 3h
            // 45m" (or the exact "Limit today at …"), carrying its own verb and following the global
            // countdown/exact mode, so — exactly like the reset label — clicking it flips that mode
            // (lifted reorder previews pass no toggle and render it inert).
            flameWarning(text: eta, state: state,
                         accessibility: eta ?? "Will reach limit",
                         action: eta == nil ? nil : onToggleResetDisplay)
        case .closeToLimit(let spare, _):
            Spacer(minLength: 8)
            Text(spare)
                .font(supportingFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .hoverTooltip(state.tooltip)
        case .healthy where data.alwaysShowPacing:
            // "Always show pacing" surfaces the projection on the otherwise-silent on-track row: the
            // same quiet secondary note as the amber case, but the cushion ("~33% left at reset")
            // rather than the spare. No flame (blue isn't a warning) and no hover tooltip — the copy
            // already *is* the projection the amber case hides in its tooltip.
            if let projection = state.tooltip {
                Spacer(minLength: 8)
                Text(projection)
                    .font(supportingFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        case .noData, .healthy, .level:
            EmptyView()
        }
    }

    /// Flame icon + optional label text, carrying the state's projection tooltip — shared by the
    /// spent and running-out cases. Only the flame is severity-tinted; the copy stays secondary
    /// (tint on glass is reserved for the symbol). An optional `action` wraps the warning in a
    /// plain button (the run-out time's countdown/exact toggle).
    @ViewBuilder
    private func flameWarning(text: String?, state: WidgetData.MeterState,
                              accessibility: String, action: (() -> Void)? = nil) -> some View {
        Spacer(minLength: 8)
        let label = HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: density.supportingPointSize - 1))
                .foregroundStyle(severityColor(state.severity))
                .accessibilityHidden(true) // the warning text alongside carries the message
            if let text {
                Text(text)
                    .font(supportingFont)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .foregroundStyle(.secondary)
        .hoverTooltip(state.tooltip)
        .accessibilityLabel(accessibility)

        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    /// Bar/copy color for a severity, or the inactive gray when there's none (the no-data track).
    private func severityColor(_ severity: WidgetData.MeterSeverity?) -> AnyShapeStyle {
        severity.map(Theme.meterFill) ?? AnyShapeStyle(Color.secondary)
    }

    /// Primary line under the bar: value+mode word on the left ("50% left"), reset/limit context on
    /// the right. The headline is the Used/Left toggle (click to flip the global meter style, with
    /// the opposite reading in its tooltip) — the exact counterpart of the reset label's toggle.
    private var primaryTextRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            headlineText
            Spacer(minLength: 8)
            trailingContext
        }
        .font(supportingFont)
        .lineLimit(1)
    }

    // The headline value is the row's payload — the number the user opened the popover to read —
    // so it sits at `.primary` (vibrant full-contrast on the popover glass); the surrounding
    // context (reset countdown, deficit) stays `.secondary`.
    @ViewBuilder
    private var headlineText: some View {
        if data.hasMeterStyleToggle, let onToggleMeterStyle {
            Button(action: onToggleMeterStyle) {
                Text(data.headline)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .hoverTooltip(data.meterStyleTooltip)
        } else {
            Text(data.headline)
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
    }

    /// Reset/limit context on the trailing edge. When it's a concrete reset countdown it becomes a
    /// click target that flips the global relative/absolute mode (with the opposite format in its
    /// tooltip), mirroring the original. Otherwise it's plain text.
    @ViewBuilder
    private var trailingContext: some View {
        if let text = data.boundedTrailingText() {
            if data.hasResetLabel(), let onToggleResetDisplay {
                Button(action: onToggleResetDisplay) {
                    Text(text).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .hoverTooltip(data.resetTooltip())
            } else {
                Text(text).foregroundStyle(.secondary)
                    .hoverTooltip(data.resetTooltip())
            }
        }
    }

    /// Unbounded: no bar. Label on the left, with a single right-aligned descriptive line ("1,503 left")
    /// and an optional secondary line ("on-device estimate") beneath it.
    private var unboundedRow: some View {
        unboundedRowContent
            .onChange(of: data.modelBreakdown) { _, _ in modelHover.dismiss() }
            // A refresh can replace the reset credits (count and expiries) while the popover is open;
            // drop it so it never lingers over a stale timeline.
            .onChange(of: data.expiriesAt) { _, _ in modelHover.dismiss() }
            .onDisappear { modelHover.dismiss() }
    }

    /// The value column reveals the model breakdown on hover, so it lights up under the pointer the way
    /// a Finder / System Settings list row does — the native cue that "this is a target." Lit the moment
    /// the pointer arrives (`overInline`, before the reveal dwell) and held lit while the popover is open,
    /// so the value reads as the popover's source. Both flags live on `modelHover`, so the panel's close
    /// path (`dismissAll`) clears the highlight even though this view's state survives `orderOut`. Only
    /// rows that actually have a breakdown light up.
    private var showValueHighlight: Bool {
        hasHoverPopover && (modelHover.overInline || modelHover.isPresented)
    }

    /// Whether the value column reveals a hover popover: the model breakdown on spend rows, or the
    /// resets timeline on the Codex rate-limit-resets row. One `modelHover` coordinator drives both — a
    /// row is only ever one kind — so lighting the value and anchoring the popover share the spend
    /// row's machinery. The resets row qualifies even at "0 available" (empty `expiriesAt`), so its
    /// empty-state popover stays reachable — but only with real data: a "No data" tile must not open a
    /// popover that reads as "zero credits" (`hasModelBreakdown` already carries its own `hasData`).
    private var hasHoverPopover: Bool {
        data.hasModelBreakdown || (data.showsResetExpiries && data.hasData)
    }

    private var unboundedRowContent: some View {
        HStack(alignment: .center, spacing: 10) {
            labelColumn
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    expiryStatusDot
                    Text(data.unboundedDetail)
                        .font(supportingFont)
                        .foregroundStyle(.primary) // the value is the row's payload — match the bounded headline
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        // Hover target is the value text itself, not the whole row — the same
                        // per-element pattern the bounded row uses for "x left" and "Resets in …". Reveals
                        // the exact figures the compact value shortens, or "No usage in this period" on a
                        // zero row; nil (no tooltip) on a small, already-full, non-zero row. Suppressed
                        // when the model-breakdown popover is wired up — a text bubble and a popover
                        // fighting over the same hover reads as two competing surfaces, and the panel's
                        // per-model tooltips carry the exact figures instead. The resets row likewise
                        // drops its tooltip — the timeline popover replaces it.
                        .hoverTooltip(hasHoverPopover ? nil : data.unboundedValueTooltip)
                }
                if let subtitle = data.unboundedSubtitle {
                    // Secondary, not tertiary: the subtitle is informational ("on-device estimate"),
                    // and tertiary is reserved for inactive content on glass.
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.trailing)
            // A quaternary chip behind the value — the app's subtle-fill token, in the shared 6pt
            // continuous corner — signals the value is interactive before the breakdown even opens.
            // Negative-inset so it hugs the figure without changing the row's height (the text-row
            // rhythm that clusters Today / Yesterday / Last 30 Days must not shift), and a quick
            // opacity fade in/out matches macOS hover states.
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .padding(.horizontal, -7)
                    .padding(.vertical, -4)
                    .opacity(showValueHighlight ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: showValueHighlight)
            // Both the hover trigger and the popover anchor live on the value column, not the whole
            // row: hovering the label (or empty gap) shouldn't reveal the breakdown — only the figure
            // it explains should — and the arrow then centers on that figure, matching the trend
            // popover's anchoring off the sparkline strip.
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard hasHoverPopover else {
                    modelHover.dismiss()
                    return
                }
                if case .active = phase {
                    modelHover.inlineHover(true)
                } else {
                    modelHover.inlineHover(false)
                }
            }
            .popover(
                isPresented: Binding(
                    get: { hasHoverPopover && modelHover.isPresented },
                    // A click-outside dismiss removes the detail view without an `.ended` hover event,
                    // so a plain assignment would strand `overDetail == true` and block future hides.
                    set: { if !$0 { modelHover.dismiss() } }
                ),
                arrowEdge: .top
            ) {
                if let breakdown = data.modelBreakdown {
                    ModelUsageDetail(title: data.title, breakdown: breakdown) { inside in
                        modelHover.detailHover(inside)
                    }
                } else if data.showsResetExpiries {
                    RateLimitResetsDetail(title: data.title, count: data.resetCreditCount,
                                          expiries: data.expiriesAt) { inside in
                        modelHover.detailHover(inside)
                    }
                }
            }
        }
    }

    /// Small blue/yellow/red status dot shown just before the value when the row carries reset-credit
    /// expiries — colored by the soonest expiry. The per-credit detail (which credits, expiring when)
    /// lives in the resets popover the value column now reveals on hover, so the dot carries no tooltip
    /// of its own. Renders nothing when no credit is available (an empty `expiriesAt`).
    @ViewBuilder
    private var expiryStatusDot: some View {
        if let severity = data.expirySeverity() {
            Circle()
                .fill(severityColor(severity))
                .frame(width: 6, height: 6)
                .accessibilityLabel(expiryStatusAccessibilityLabel(severity))
        }
    }

    private func expiryStatusAccessibilityLabel(_ severity: WidgetData.MeterSeverity) -> String {
        switch severity {
        case .normal: return "Reset credits expire in more than 7 days"
        case .warning: return "A reset credit expires within 7 days"
        case .critical: return "A reset credit expires within 48 hours"
        }
    }

    private var labelColumn: some View {
        HStack(spacing: 4) {
            Text(data.title)
                // Same point size as the trailing value so the single-line row reads tight;
                // semibold alone keeps the name/value hierarchy.
                .font(.system(size: density.supportingPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            unknownModelWarningIcon
        }
    }

    /// Amber warning triangle shown just after a spend tile's label (Today / Yesterday / Last 30 Days)
    /// when the period used a model the pricing manifest can't price, so its cost is incomplete. Hovering
    /// lists the unknown model names. Renders nothing otherwise.
    @ViewBuilder
    private var unknownModelWarningIcon: some View {
        if data.hasUnknownModels {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: density.supportingPointSize - 1))
                .foregroundStyle(severityColor(.warning))
                .hoverTooltip(data.unknownModelTooltip)
                .accessibilityLabel("This period used a model with unknown pricing")
        }
    }

    /// Full-width capsule meter — the Tahoe-era level-indicator form (capsule, full-height
    /// leading-anchored fill, like the redesigned Slider / Control Center). Deliberately NOT the
    /// native linear `Gauge`/`ProgressView`, which Tahoe left as the thin legacy bar. The fill is
    /// a flat **system color** carrying the pace verdict (blue = well within limits, yellow =
    /// projected to land inside the last 10%, red = projected to run out; `Theme.meterFill` /
    /// `MeterState.severity`) at full strength on the opaque popover surface; the earlier
    /// provider-brand gradient was removed deliberately so the bar's color always reads as state.
    /// Empty + colorless without data. A thin tick marks the even-pace line — where usage would sit
    /// if it burned evenly across the reset window — on yellow and red bars always, and on blue when
    /// "always show pacing" is on. The tick rides in an overlay so it pokes out top and bottom without
    /// changing the bar's height. Hovering shows the pace projection (`MeterState.tooltip`).
    private func meter(_ state: WidgetData.MeterState) -> some View {
        let tick = data.paceTick(for: state)
        return GeometryReader { proxy in
            // Track + fill define the bar's height; the tick rides in an `.overlay` so its taller frame
            // pokes out top and bottom without stretching the capsules. (As a ZStack sibling it grew the
            // stack and the flexible capsules stretched with it, so a tick'd bar read as a thicker bar.)
            ZStack(alignment: .leading) {
                // Semantic quaternary fill (not an opacity-faded color) so the track stays vibrant
                // on glass and adapts to Increase Contrast / Reduce Transparency.
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(partyMode ? PartyMode.meterFill : severityColor(state.severity))
                    .frame(width: fillWidth(track: proxy.size.width))
            }
            .overlay(alignment: .leading) {
                if let tick {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: Self.paceTickWidth, height: density.meterHeight + Self.paceTickOverhang)
                        .offset(x: paceTickOffset(track: proxy.size.width, fraction: tick))
                }
            }
        }
        .frame(height: density.meterHeight)
        .animation(Motion.spring, value: data.fraction)
        .accessibilityHidden(true)
        .hoverTooltip(state.tooltip)
    }

    private static let paceTickWidth: CGFloat = 2
    /// How much taller than the bar the tick is, so it pokes out slightly above and below (half each
    /// end). The bar itself stays at `meterHeight` regardless — the tick lives in an overlay.
    private static let paceTickOverhang: CGFloat = 4

    /// Leading offset that centers the tick on its fraction, clamped so the tick never pokes past
    /// either rounded end of the track.
    private func paceTickOffset(track: CGFloat, fraction: Double) -> CGFloat {
        let centered = track * fraction - Self.paceTickWidth / 2
        return min(max(centered, 0), max(track - Self.paceTickWidth, 0))
    }

    /// Fill width with a minimum-visible rule: any non-zero fraction renders at least a full circle
    /// (width = bar height) so 1–2% never squashes into an invisible sliver — the same idea as the
    /// menu-bar bars' minimum fill.
    private func fillWidth(track: CGFloat) -> CGFloat {
        guard data.hasData, data.fraction > 0 else { return 0 }
        return max(density.meterHeight, track * data.fraction)
    }
}
