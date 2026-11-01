import SwiftUI

struct PriorityDashboardView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    let onOpenAccount: (String) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            PriorityBoardList(
                board: PriorityBoard.make(accounts: dataStore.accounts(in: layout.displayGroups), now: context.date),
                now: context.date,
                onOpenAccount: onOpenAccount
            )
        }
    }
}

struct PriorityBoardList: View {
    let board: PriorityBoard
    let now: Date
    let onOpenAccount: (String) -> Void

    private static let green = Color(nsColor: .systemGreen)
    private static let gaugeSide: CGFloat = 32

    var body: some View {
        switch board.summary {
        case .waitingForUsage:
            waitingRow
        case .allClear:
            allClear
        case .listed:
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                if board.attention.isEmpty { clearRow } else { attentionSection }
                if !board.usedUp.isEmpty { usedUpSection }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Running Out")
            ForEach(board.attention) { item in
                row(for: item) { attentionRow(item) }
            }
        }
    }

    private var usedUpSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Used Up")
            ForEach(board.usedUp) { item in
                row(for: item) { usedUpRow(item) }
            }
        }
        .opacity(0.5)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row<Content: View>(for item: PriorityItem, @ViewBuilder content: () -> Content) -> some View {
        Button { onOpenAccount(item.provider.id) } label: {
            content()
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func attentionRow(_ item: PriorityItem) -> some View {
        HStack(spacing: 10) {
            PriorityGauge(fraction: item.data.remainingFraction, severity: item.reason.severity, icon: item.provider.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.data.title)
                    .font(.system(size: 13, weight: .medium))
                Text(item.provider.accountName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .truncationMode(item.provider.isNamedByEmail ? .middle : .tail)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.data.amountText)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                if let reset = item.data.compactResetText(now: now) {
                    Text(reset)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .frame(height: 46)
    }

    private func usedUpRow(_ item: PriorityItem) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(id: item.provider.icon, side: 15, inset: 0.04)
                .frame(width: 16)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.data.title)
                    .font(.system(size: 13))
                Text(item.provider.accountName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .truncationMode(item.provider.isNamedByEmail ? .middle : .tail)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let note = item.usedUpNote(now: now) {
                Text(note)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: 28)
    }

    private var clearRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.green)
                .frame(width: Self.gaugeSide, height: Self.gaugeSide)
                .background(Self.green.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("All Clear")
                    .font(.system(size: 13, weight: .medium))
                Text("Nothing is running out.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 46)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var allClear: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(Self.green.opacity(0.10), lineWidth: 1).frame(width: 110, height: 110)
                Circle().stroke(Self.green.opacity(0.20), lineWidth: 1).frame(width: 86, height: 86)
                Circle().fill(Self.green.opacity(0.16)).frame(width: 60, height: 60)
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Self.green)
            }
            .frame(width: 112, height: 112)
            .padding(.bottom, 12)
            .accessibilityHidden(true)
            Text("All Clear")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 3)
            Text("Nothing needs your attention right now.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 22)
    }

    private var waitingRow: some View {
        Text("Waiting for Usage")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
    }
}

/// What's left of a limit as a ring around its provider's mark.
private struct PriorityGauge: View {
    let fraction: Double
    let severity: WidgetData.MeterSeverity
    let icon: String

    private static let lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .inset(by: Self.lineWidth / 2)
                .stroke(.quaternary, lineWidth: Self.lineWidth)
            Circle()
                .inset(by: Self.lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(Theme.severityColor(severity), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ProviderIcon(id: icon, side: 16, inset: 0.04)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}
