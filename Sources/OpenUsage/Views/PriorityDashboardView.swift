import SwiftUI

struct PriorityDashboardView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(PopoverState.self) private var popover

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            PriorityBoardList(
                board: dataStore.priorityBoard(in: layout.displayGroups, pinned: layout.state.priorityPinIDs, now: context.date),
                now: context.date,
                onToggleMeterStyle: { dataStore.meterStyle.toggle() },
                onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() },
                onShowAllUsage: { popover.dashboardTab = .allUsage },
                onFixAccount: { popover.openAccounts($0) },
                onSetPinned: { layout.setMetric($0, pinned: $1) }
            )
        }
    }
}

struct PriorityBoardList: View {
    let board: PriorityBoard
    let now: Date
    /// Left out where nothing can be clicked, as in a picture.
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?
    var onShowAllUsage: (() -> Void)?
    var onFixAccount: ((String) -> Void)?
    var onSetPinned: ((String, Bool) -> Void)?

    private static let green = Color(nsColor: .systemGreen)
    private static let gaugeSide: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.margin) {
            if !board.pinned.isEmpty { pinnedSection }
            summary
            if !board.waiting.isEmpty { waitingSection }
            if !board.usedUp.isEmpty { usedUpSection }
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch board.summary {
        case .waitingForUsage:
            EmptyView()
        case .noReportedLimits:
            VStack(spacing: 4) {
                Text("No Reported Limits")
                    .font(.system(size: 13, weight: .medium))
                allUsageButton
            }
            .frame(maxWidth: .infinity, minHeight: 46)
        case .unavailable:
            accountNotices
        case .allClear, .listed:
            VStack(alignment: .leading, spacing: PanelMetrics.margin) {
                if !board.attention.isEmpty || board.showsClearRow { attentionSection }
                if !board.useItOrLoseIt.isEmpty { useItOrLoseItSection }
                if !board.notices.isEmpty { accountNotices }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var allUsageButton: some View {
        if let onShowAllUsage {
            Button("View All Usage", action: onShowAllUsage)
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    private var accountNotices: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                sectionLabel("Needs Attention")
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
            }
            ForEach(board.notices) { notice in
                noticeRow(notice)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeRow(_ notice: PriorityBoard.AccountNotice) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(id: notice.provider.icon, side: 15, inset: 0.04)
                .frame(width: 16)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notice.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if let account = notice.provider.labelBesideName {
                    Text(account)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .truncationMode(notice.provider.isNamedByEmail ? .middle : .tail)
                        .concealingAccountName(of: notice.provider)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let onFixAccount {
                Button("Fix") { onFixAccount(notice.provider.id) }
                    .controlSize(.small)
            }
        }
        .frame(height: 28)
        .accessibilityValue(notice.message)
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Pinned")
            ForEach(board.pinned) { pin in
                limitRow(pin.provider, pin.data, severity: .normal)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .contextMenu { pinMenu(pin.id, pinned: true) }
            }
        }
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Running Out")
            if board.attention.isEmpty { clearRow }
            ForEach(board.attention) { item in
                limitRow(item.provider, item.data, severity: item.reason.severity,
                         callout: item.runOutText(now: now).map { ($0, Theme.severityTextColor(.warning)) })
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .contextMenu { pinMenu(item.id, pinned: item.isPinned) }
            }
        }
    }

    private var usedUpSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Used Up")
            ForEach(board.usedUp) { item in
                usedUpRow(item)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .contextMenu { pinMenu(item.id, pinned: item.isPinned) }
            }
        }
        .opacity(0.5)
    }

    private var useItOrLoseItSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Use It or Lose It")
            ForEach(board.useItOrLoseIt) { item in
                limitRow(item.provider, item.data, severity: item.reason.severity,
                         callout: item.resetsInText(now: now).map { ($0, Theme.severityTextColor(.normal)) })
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .contextMenu { pinMenu(item.id, pinned: item.isPinned) }
            }
        }
    }

    @ViewBuilder
    private func pinMenu(_ metricID: String, pinned: Bool) -> some View {
        if let onSetPinned {
            DashboardMenu(sections: [[DashboardMenus.pin(metricID, pinned: pinned)]]) { _ in onSetPinned(metricID, !pinned) }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    /// Flips a reading the way a click on it does in All Usage.
    @ViewBuilder
    private func toggling(_ action: (() -> Void)?, @ViewBuilder label: () -> some View) -> some View {
        if let action {
            Button(action: action, label: label)
                .buttonStyle(.plain)
        } else {
            label()
        }
    }

    /// `callout` takes the reset's place: when a limit listed only for burning fast runs out, or when one listed to
    /// use it or lose it resets.
    private func limitRow(
        _ provider: Provider, _ data: WidgetData, severity: WidgetData.MeterSeverity, callout: (text: String, color: Color)? = nil
    ) -> some View {
        HStack(spacing: 10) {
            PriorityGauge(fraction: data.fraction, severity: severity, icon: provider.icon, paceMark: data.paceMark(now: now))
            VStack(alignment: .leading, spacing: 1) {
                Text(data.title)
                    .font(.system(size: 13, weight: .medium))
                Text(provider.accountName)
                    .accessibilityLabel(provider.fullName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .truncationMode(provider.isNamedByEmail ? .middle : .tail)
                    .concealingAccountName(of: provider)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                toggling(data.hasMeterStyleToggle ? onToggleMeterStyle : nil) {
                    Text(data.amountText)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
                if let callout {
                    Text(callout.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(callout.color)
                        .monospacedDigit()
                } else if let reset = data.compactResetText(now: now) {
                    toggling(onToggleResetDisplay) {
                        Text(reset)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
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
                    .accessibilityLabel(item.provider.fullName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .truncationMode(item.provider.isNamedByEmail ? .middle : .tail)
                    .concealingAccountName(of: item.provider)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let note = item.usedUpNote(now: now) {
                toggling(item.data.resetsAt == nil ? nil : onToggleResetDisplay) {
                    Text(note)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
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

    /// One row per account still waiting, shaped like the rows that replace it. The gauge is a plain disc,
    /// since nothing says yet which limit will show there.
    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(board.waiting) { provider in
                HStack(spacing: 10) {
                    Circle()
                        .frame(width: Self.gaugeSide, height: Self.gaugeSide)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().frame(width: 84, height: 9)
                        Capsule().frame(width: 56, height: 7)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Capsule().frame(width: 48, height: 9)
                        Capsule().frame(width: 32, height: 7)
                    }
                }
                .skeleton()
                .frame(height: 46)
                .padding(.horizontal, 4)
                .accessibilityElement()
                .accessibilityLabel("Waiting for Usage")
                .accessibilityValue(provider.fullName)
            }
        }
    }
}

/// A limit's bar as a ring around its provider's mark, filling the same way under Used or Left, with a tick
/// where it would be at an even pace.
private struct PriorityGauge: View {
    let fraction: Double
    let severity: WidgetData.MeterSeverity
    let icon: String
    let paceMark: Double?

    private static let lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .inset(by: Self.lineWidth / 2)
                .stroke(Theme.meterTrack, lineWidth: Self.lineWidth)
            Circle()
                .inset(by: Self.lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(Theme.severityColor(severity), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let paceMark {
                PaceTick(mark: paceMark)
                    .stroke(style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .blendMode(.destinationOut)
                PaceTick(mark: paceMark)
                    .stroke(Theme.paceMark, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            ProviderIcon(id: icon, side: 16, inset: 0.04)
        }
        .compositingGroup()
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

/// A short stroke across the ring's track, clockwise from 12 o'clock by `mark` of a turn.
private struct PaceTick: Shape {
    let mark: Double

    func path(in rect: CGRect) -> Path {
        let angle = mark * 2 * .pi
        func point(_ radius: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + radius * sin(angle), y: rect.midY - radius * cos(angle))
        }
        var path = Path()
        path.move(to: point(rect.width / 2 - 4.25))
        path.addLine(to: point(rect.width / 2 + 0.75))
        return path
    }
}
