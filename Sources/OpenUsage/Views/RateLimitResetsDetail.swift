import SwiftUI

/// Hover detail for the Codex rate-limit-resets row: a vertical timeline of each still-available reset
/// credit, one node per credit, ordered soonest-expiry first. Each node is a single line — a numbered,
/// severity-colored dot (the number IS the reset number; blue > 7 days, yellow within a week, red
/// within 48 hours — the same `expirySeverity` bands as the row's status dot), the exact expiry time,
/// and the countdown to it on the trailing edge. Replaces the old `HoverTooltip` list. When no credits
/// are available it shows a centered empty state. Mirrors `ModelUsageDetail` / `UsageTrendDetail`'s
/// calm — header + flat body — presented via `.popover`.
struct RateLimitResetsDetail: View {
    let title: String
    /// The row's "N available" count. Only used to disambiguate an empty `expiries` list: 0 → genuinely
    /// no credits (empty state); > 0 → credits we have but whose expiry times weren't fetched.
    let count: Int
    let expiries: [Date]
    /// Reports whether the cursor is inside the popover, so the trigger keeps it open while the cursor
    /// travels from the inline value into the popover, and closes once it leaves both.
    var onHoverChange: (Bool) -> Void

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    private static let width: CGFloat = 250

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch Self.content(count: count, expiries: expiries) {
            case .timeline(let entries): timeline(entries)
            case .unknownExpiries(let count): unknownExpiriesState(count)
            case .empty: emptyState
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
    }

    private var header: some View {
        Text(title)
            .font(.system(size: density.headerPointSize, weight: .semibold))
            .foregroundStyle(.primary)
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
    /// sequence. Each node is one line; the numbered dot rides the rail and the line runs behind it.
    private func timeline(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    rail(for: entry, isFirst: entry.id == 0, isLast: entry.id == entries.count - 1)
                    row(entry)
                }
            }
        }
    }

    /// The connector rail: a hairline split into a top and bottom half so it runs continuously through
    /// the numbered dot's center across rows, with the first node's top half and the last node's bottom
    /// half hidden (nothing to connect to beyond the ends). The dot carries the reset number.
    private func rail(for entry: Entry, isFirst: Bool, isLast: Bool) -> some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity)
                    .opacity(isFirst ? 0 : 1)
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity)
                    .opacity(isLast ? 0 : 1)
            }
            numberedDot(entry)
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

    private func row(_ entry: Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.time)
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let countdown = entry.countdown {
                Text(countdown)
                    .font(.system(size: density.supportingPointSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityLabel)
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
                severity: WidgetData.expirySeverity(secondsRemaining: date.timeIntervalSince(now)),
                time: (imminent || absolute == nil) ? "Expiring soon" : absolute!,
                countdown: imminent ? nil : relative
            )
        }
    }
}
