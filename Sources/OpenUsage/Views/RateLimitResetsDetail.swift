import SwiftUI

/// Hover detail for the Codex rate-limit-resets row: a vertical timeline of each still-available reset
/// credit, one node per credit, ordered soonest-expiry first. Each node is a single line — a numbered,
/// severity-colored dot (the number IS the reset number; blue > 7 days, yellow within a week, red
/// within 48 hours — the same `expirySeverity` bands as the row's status dot), the exact expiry time,
/// and the countdown to it on the trailing edge. Replaces the old `HoverTooltip` list. When no credits
/// are available it shows a centered empty state. Mirrors `ModelUsageDetail` / `UsageTrendDetail`'s
/// calm — header + flat body — presented via `.popover`.
struct RateLimitResetsDetail: View {
    private typealias Entry = RateLimitResetsPresentation.Entry

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
            switch RateLimitResetsPresentation.content(count: count, expiries: expiries) {
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

}
