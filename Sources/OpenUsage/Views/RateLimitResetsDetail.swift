import SwiftUI

/// Hover detail for the Codex rate-limit-resets row: a vertical timeline of each still-available reset
/// credit, one node per credit, ordered soonest-expiry first. Each node is a single line — a numbered,
/// severity-colored dot (the number IS the reset number; blue > 7 days, yellow within a week, red
/// within 48 hours — the same `expirySeverity` bands as the row's status dot), the exact expiry time,
/// and the countdown to it on the trailing edge. Replaces the old `HoverTooltip` list. When no credits
/// are available it shows a centered empty state. Mirrors `ModelUsageDetail` / `UsageTrendDetail`'s
/// calm — header + flat body — presented via `.popover`.
///
/// When a `claim` closure is supplied (the Codex resets row), each node also becomes claimable: hovering
/// a node reveals a "Use" affordance, clicking it expands that node in place into an inline confirm, and
/// confirming runs the claim and shows the outcome. `claim` is `nil` for any non-claimable row, which
/// renders exactly the read-only timeline. NOTE: the claim is currently MOCKED — `WidgetRowView` passes a
/// fake closure that always succeeds after a short delay so the flow can be tested without spending a real
/// credit. Wiring it to the live consume endpoint is a drop-in replacement of that closure.
struct RateLimitResetsDetail: View {
    let title: String
    /// The row's "N available" count. Only used to disambiguate an empty `expiries` list: 0 → genuinely
    /// no credits (empty state); > 0 → credits we have but whose expiry times weren't fetched.
    let count: Int
    let expiries: [Date]
    /// Reports whether the cursor is inside the popover, so the trigger keeps it open while the cursor
    /// travels from the inline value into the popover, and closes once it leaves both.
    var onHoverChange: (Bool) -> Void
    /// Pins the popover open across the confirm / in-flight steps so a cursor slip can't tear the flow
    /// down mid-claim. `nil` when there's no claim flow (read-only timeline).
    var onPinChange: ((Bool) -> Void)?
    /// Claims the reset credit expiring at the given instant. `nil` makes the timeline read-only (no
    /// "Use" affordance). Currently a mock; see the type doc.
    var claim: ((Date) async -> ResetClaimOutcome)?

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    /// Which credits this popover has already claimed (keyed by expiry instant, which is unique per
    /// credit), so a claimed node drops out of the timeline immediately without waiting for a refresh.
    @State private var claimedExpiries: Set<Date> = []
    /// The node currently in its inline confirm step, or being claimed, keyed by expiry instant.
    @State private var confirmingExpiry: Date?
    @State private var claimingExpiry: Date?
    /// The node the cursor is currently over (drives the "Use" reveal).
    @State private var hoveredExpiry: Date?
    /// The result banner shown above the timeline after a claim resolves.
    @State private var banner: Banner?
    /// Mock stand-in for "current usage is already at 0%": true once a reset has been claimed this
    /// session, which disables the remaining "Use" buttons (a fresh reset means there's nothing left to
    /// reset). The live version will read this from the current usage snapshot instead.
    @State private var usageAtZero = false

    private static let width: CGFloat = 250

    /// A claim in flight or awaiting confirmation — freezes the other nodes so only one claim happens at
    /// a time and the focus stays on the active node.
    private var claimInProgress: Bool { confirmingExpiry != nil || claimingExpiry != nil }

    /// The credits still shown: the supplied expiries minus any claimed this session.
    private var visibleExpiries: [Date] {
        expiries.filter { !claimedExpiries.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner {
                bannerView(banner)
                    // Unfold from the top edge as the claimed node collapses below — one combined motion.
                    .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
            }
            switch Self.content(count: count - claimedExpiries.count, expiries: visibleExpiries) {
            case .timeline(let entries): timeline(entries)
            case .unknownExpiries(let count): unknownExpiriesState(count)
            case .empty: emptyState
            }
        }
        .padding(14)
        .frame(width: Self.width)
        // Report the ideal (content-hugging) height as the fixed size, so collapsing the confirm card
        // back to a one-line node shrinks the popover again — without this, NSPopover keeps the largest
        // height it has ever measured (it grows on Use but never scales back on Cancel).
        .fixedSize(horizontal: false, vertical: true)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
    }

    /// Centered "no resets" state — an invitation-free statement, not an apology, matching the app's
    /// other empty copy.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("You have no rate limit resets")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Shown when the row has credits but their per-credit expiry list wasn't fetched (the usage-body
    /// count fallback): state the count so the popover never contradicts the row's "N available", and
    /// say plainly that the expiry times aren't available rather than implying there are none.
    private func unknownExpiriesState(_ count: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(count) available")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.primary)
            Text("Expiry times unavailable")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// The nodes, connected top-to-bottom by a hairline rail so the credits read as a soonest-first
    /// sequence. The numbered dot always lives in the left rail column — never inside a node's content —
    /// so an expanded node (the confirm card) keeps its dot on the rail, top-aligned with its first line,
    /// and the connector runs unbroken down to the next node.
    private func timeline(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Identity by expiry instant, not positional index: after a claim removes a node the others
            // renumber, and index identity would read as "every row replaced" instead of one row leaving
            // — date identity lets the removal collapse while the survivors slide up.
            ForEach(entries, id: \.date) { entry in
                let isFirst = entry.id == 0
                let isLast = entry.id == entries.count - 1
                HStack(alignment: .top, spacing: 10) {
                    rail(for: entry, isFirst: isFirst, isLast: isLast, dotCenterY: dotCenterY(for: entry))
                    node(entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Where the dot's center sits from the top of the row, so the rail can place the dot and route the
    /// connector through it. A single-line node centers the dot on its one line; the confirm card aligns
    /// it with the card's first line ("Use this reset?") rather than the card's middle.
    private func dotCenterY(for entry: Entry) -> CGFloat {
        confirmingExpiry == entry.date ? confirmCardPadding + 9 : nodeHeight / 2
    }

    /// The connector rail: a hairline in two segments — a fixed-height top segment (row top → dot
    /// center) and a stretchy bottom segment (dot center → row bottom) — so it runs unbroken through the
    /// dot and, on a tall confirm node, all the way down to the next node. The first node hides its top
    /// segment and the last its bottom (nothing to connect to beyond the ends). Segments, not a
    /// GeometryReader path: `maxHeight: .infinity` rectangles reliably stretch to the row's full height
    /// inside the HStack, where a GeometryReader collapses to its 10pt default and cuts the line short.
    private func rail(for entry: Entry, isFirst: Bool, isLast: Bool, dotCenterY: CGFloat) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(height: dotCenterY)
                    .opacity(isFirst ? 0 : 1)
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity)
                    .opacity(isLast ? 0 : 1)
            }
            numberedDot(entry).padding(.top, dotCenterY - 9)
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }

    private func numberedDot(_ entry: Entry) -> some View {
        ZStack {
            Circle().fill(Theme.meterFill(entry.severity)).frame(width: 18, height: 18)
            Text("\(entry.number)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Self.numberColor(entry.severity))
        }
    }

    /// The number sits on a saturated system fill, so it takes the fill's paired foreground: dark on the
    /// bright yellow, white on the blue and red.
    private static func numberColor(_ severity: WidgetData.MeterSeverity) -> Color {
        severity == .warning ? .black : .white
    }

    /// One timeline node's content (no dot — that lives on the rail): the read-only/claimable line, or,
    /// when it's the active node, the inline confirm or in-flight treatment.
    @ViewBuilder
    private func node(_ entry: Entry) -> some View {
        if confirmingExpiry == entry.date {
            confirmRow(entry)
                // Grow out of / collapse back into the one-line node it replaces: anchored at the top so
                // the first line (which the rail dot aligns to) stays put while the card unfolds below it.
                .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
        } else if claimingExpiry == entry.date {
            claimingRow()
                .transition(.opacity)
        } else {
            row(entry)
                // Freeze and fade the other nodes while a claim is being confirmed or run, so only the
                // active node reads as live.
                .opacity(claimInProgress ? 0.45 : 1)
                .allowsHitTesting(!claimInProgress)
                .transition(.opacity)
        }
    }

    /// Fixed height for a resting/claimable node so swapping the trailing countdown for the "Use"
    /// button on hover can't change the row's height (which made the rows jump). The confirm node is
    /// deliberately taller — that's a click away, not a hover.
    private var nodeHeight: CGFloat { density.supportingPointSize + 18 }
    /// Inner padding of the confirm card, shared with `dotCenterY` so the rail dot lines up with the
    /// card's first line.
    private let confirmCardPadding: CGFloat = 10

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 8) {
            Text(entry.time)
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing(entry)
        }
        .frame(height: nodeHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredExpiry = entry.date }
            else if hoveredExpiry == entry.date { hoveredExpiry = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityLabel)
    }

    /// The trailing control on a resting node: the "Use" button when the row is claimable and hovered,
    /// otherwise the countdown. When usage is already at 0% the button is present but disabled, with the
    /// reason in its tooltip rather than as inline text. Native small bordered button — no accent fill.
    @ViewBuilder
    private func trailing(_ entry: Entry) -> some View {
        // A quick crossfade between the countdown and the Use button (both transitions are opacity-only;
        // the animation rides `hoveredExpiry`), so the reveal reads as a fade, not a pop.
        Group {
            if claim != nil, hoveredExpiry == entry.date, !claimInProgress {
                Button("Use") { beginConfirm(entry.date) }
                    .controlSize(.small)
                    .disabled(usageAtZero)
                    .hoverTooltip(usageAtZero ? "Usage is already at 0%, nothing to reset" : nil)
                    .transition(.opacity)
            } else if let countdown = entry.countdown {
                Text(countdown)
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredExpiry)
    }

    /// The active node's inline confirm: a short scope-aware question and Reset / Cancel. The numbered
    /// dot stays on the rail (top-aligned with the question), so this is just the card body — no modal,
    /// the claim stays inside the popover.
    private func confirmRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use this reset?")
                .font(.system(size: density.supportingPointSize, weight: .medium))
                .foregroundStyle(.primary)
            Text("Immediately reset your usage limits. This can't be undone.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { runClaim(entry.date) } label: {
                    Text("Reset").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button { cancelConfirm() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(confirmCardPadding)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5))
        }
        .padding(.vertical, 4)
    }

    /// The active node while the claim runs — the dot stays on the rail; the content reads "Resetting…"
    /// with a trailing spinner.
    private func claimingRow() -> some View {
        HStack(spacing: 8) {
            Text("Resetting your usage…")
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ProgressView().controlSize(.small)
        }
        .frame(height: nodeHeight)
    }

    /// The result banner: a leading icon and a short line, tinted by outcome (green success, blue info,
    /// amber/red for the unavailable and failure cases).
    private func bannerView(_ banner: Banner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.icon)
                .font(.system(size: 14))
                .foregroundStyle(banner.tint)
                .accessibilityHidden(true)
            Text(banner.text)
                .font(.system(size: density.supportingPointSize, weight: .medium))
                .foregroundStyle(banner.tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(banner.tint.opacity(0.12))
        }
    }

    // MARK: - Claim flow actions

    /// One clock for every claim-flow layout change (card expand/collapse, node swap, banner, credit
    /// removal), so the rail, the rows, and the popover height all move together.
    private static let flowAnimation: Animation = .snappy(duration: 0.25)

    private func beginConfirm(_ date: Date) {
        withAnimation(Self.flowAnimation) {
            banner = nil
            hoveredExpiry = nil
            confirmingExpiry = date
        }
        onPinChange?(true)
    }

    private func cancelConfirm() {
        withAnimation(Self.flowAnimation) {
            confirmingExpiry = nil
        }
        onPinChange?(false)
    }

    private func runClaim(_ date: Date) {
        guard let claim else { return }
        withAnimation(Self.flowAnimation) {
            confirmingExpiry = nil
            claimingExpiry = date
        }
        Task {
            let outcome = await claim(date)
            withAnimation(Self.flowAnimation) {
                claimingExpiry = nil
                apply(outcome, for: date)
            }
            onPinChange?(false)
        }
    }

    private func apply(_ outcome: ResetClaimOutcome, for date: Date) {
        switch outcome {
        case .success:
            claimedExpiries.insert(date)
            usageAtZero = true
            banner = .init(text: "Reset claimed. Enjoy!", icon: "checkmark.circle.fill", tint: .green)
        case .nothingToReset:
            usageAtZero = true
            banner = .init(text: "Your usage doesn't need a reset yet", icon: "info.circle.fill", tint: .accentColor)
        case .noCredit:
            claimedExpiries.insert(date)
            banner = .init(text: "That reset is no longer available", icon: "exclamationmark.triangle.fill", tint: .orange)
        case .failed:
            banner = .init(text: "Couldn't reset usage. Please try again.", icon: "xmark.circle.fill", tint: .red)
        }
    }

    /// The tint + glyph for a result banner.
    struct Banner: Equatable {
        let text: String
        let icon: String
        let tint: Color
    }

    /// What the body renders, resolved once from the count and expiry list so the "empty vs. count-only
    /// vs. timeline" choice is unit-testable and can't drift between the view and its tests.
    enum Content: Equatable {
        case timeline([Entry])
        case unknownExpiries(count: Int)
        case empty
    }

    /// Empty `expiries` is ambiguous: a genuinely empty balance (`count == 0`) shows the empty state,
    /// but a positive `count` with no expiries means the dedicated expiry fetch was unavailable and the
    /// row fell back to the usage-body count — show that count rather than "no resets".
    static func content(count: Int, expiries: [Date], now: Date = Date()) -> Content {
        let entries = entries(from: expiries, now: now)
        if !entries.isEmpty { return .timeline(entries) }
        if count > 0 { return .unknownExpiries(count: count) }
        return .empty
    }

    /// One timeline node's display strings, derived from a credit's expiry instant. Pure and static so
    /// the phrasing is unit-testable without a view.
    struct Entry: Identifiable, Equatable {
        let id: Int          // 0-based row index (soonest first)
        let number: Int      // 1-based reset number, shown inside the dot
        let date: Date       // the credit's expiry instant — identity for the claim flow
        let severity: WidgetData.MeterSeverity
        let time: String       // exact expiry, e.g. "Jul 12 at 5:30 PM"; "Expiring soon" when imminent
        let countdown: String? // "12d 18h"; nil when imminent (no useful countdown to show)

        var accessibilityLabel: String {
            "Reset \(number), \(time)" + (countdown.map { ", expires in \($0)" } ?? "")
        }
    }

    /// Build the timeline entries from raw expiry instants: sort soonest-first, number from 1, and pair
    /// each exact expiry time with its countdown. A past-due or ≤5-minute expiry can't print a useful
    /// exact time or countdown, so it reads "Expiring soon" with no trailing countdown. Imminence keys
    /// off the *relative* window — `Formatters.whenLabel(.relative)` collapses to `soon` at ≤5 minutes,
    /// while `.absolute` only collapses once past-due — so both formats agree instead of the exact time
    /// printing a wall-clock while the countdown reads "soon".
    static func entries(from expiries: [Date], now: Date = Date()) -> [Entry] {
        expiries.sorted().enumerated().map { index, date in
            let relative = Formatters.whenLabel(at: date, mode: .relative, now: now)
            let absolute = Formatters.whenLabel(at: date, mode: .absolute, now: now)
            let imminent = (relative == nil || relative == Formatters.imminent)
            return Entry(
                id: index,
                number: index + 1,
                date: date,
                severity: WidgetData.expirySeverity(secondsRemaining: date.timeIntervalSince(now)),
                time: (imminent || absolute == nil) ? "Expiring soon" : absolute!,
                countdown: imminent ? nil : relative
            )
        }
    }
}

/// The outcome of a reset-credit claim — mirrors the four `code` values the Codex consume endpoint
/// returns (`reset`/`already_redeemed` collapse to `.success`), plus a transport/HTTP `.failed`.
enum ResetClaimOutcome {
    case success
    case nothingToReset
    case noCredit
    case failed
}
