import SwiftUI

struct DashboardProviderSection<Header: View, Account: View>: View {
    let family: DashboardFamily
    @ViewBuilder var header: Header
    @ViewBuilder var account: (DashboardAccount) -> Account

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardGrid.headerGap) {
            header
            VStack(alignment: .leading, spacing: DashboardGrid.accountSpacing) {
                ForEach(family.accounts) { account($0) }
            }
            .padding(DashboardGrid.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

extension DashboardProviderSection where Header == DashboardProviderHeader {
    init(family: DashboardFamily, plans: [String: String] = [:], @ViewBuilder account: @escaping (DashboardAccount) -> Account) {
        self.init(
            family: family,
            header: { DashboardProviderHeader(family: family, plan: family.soleAccount.flatMap { plans[$0.id] }) },
            account: account
        )
    }
}

struct DashboardProviderHeader: View {
    let family: DashboardFamily
    var plan: String?
    var status = AccountStatus()
    var onCopyScreenshot: (() -> Bool)?

    @State private var isHovered = false
    @State private var copied = false

    private var provider: Provider { family.provider }

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DashboardGrid.amountGap) {
                title
                if let plan {
                    Text(plan)
                        .font(DashboardGrid.planFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            status.glyph
                .padding(.leading, DashboardGrid.amountGap)
            Spacer(minLength: DashboardGrid.columnGap)
            logoOrCopy
        }
        .padding(.horizontal, DashboardGrid.cardPadding + DashboardGrid.inset)
        .frame(height: DashboardGrid.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var title: some View {
        if let account = family.soleAccount {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if account.provider.labelBesideName != nil {
                    Text("\(provider.displayName) — ")
                        .font(DashboardGrid.headerFont)
                        .lineLimit(1)
                        .fixedSize()
                }
                AccountNameLabel(account: account, font: DashboardGrid.headerFont)
            }
        } else {
            Text(provider.displayName)
                .font(DashboardGrid.headerFont)
                .lineLimit(1)
        }
    }

    private var logoOrCopy: some View {
        ZStack(alignment: .trailing) {
            ProviderIcon(id: provider.icon, side: DashboardGrid.iconSize, inset: 0.04)
                .opacity(onCopyScreenshot != nil && (isHovered || copied) ? 0 : 1)
                .accessibilityHidden(true)
            if let onCopyScreenshot {
                CopyFeedbackButton(
                    accessibilityLabel: "Copy \(provider.displayName) Screenshot",
                    isRevealed: isHovered,
                    copied: $copied,
                    action: onCopyScreenshot
                )
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered || copied)
    }
}

struct DashboardAccountCaption: View {
    let account: DashboardAccount
    var plan: String?
    var status = AccountStatus()

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            AccountNameLabel(account: account, font: DashboardGrid.captionFont)
                .foregroundStyle(.secondary)
            status.glyph
            Spacer(minLength: DashboardGrid.columnGap)
            if let plan {
                Text(plan)
                    .font(DashboardGrid.planFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, DashboardGrid.inset)
        .frame(height: DashboardGrid.captionHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// An account's name, marked when it's mirrored from a CLIProxyAPI hub.
struct AccountNameLabel: View {
    let account: DashboardAccount
    let font: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            AccountName(account: account, font: font)
            if account.provider.hubHost != nil {
                Text(" \(Image(nsImage: ProviderMarks.image(for: CLIProxyHub.markID, side: DashboardGrid.planNSFont.capHeight, inset: 0)).renderingMode(.template))")
                    .font(font)
                    .fixedSize()
            }
        }
    }
}

struct AccountName: View {
    let account: DashboardAccount
    let font: Font

    @Environment(AccountRenameStore.self) private var renaming: AccountRenameStore?

    var body: some View {
        if let renaming, let edit = renaming.edit, edit.providerID == account.id {
            InlineRenameField(renaming: renaming, edit: edit)
                .font(font)
                .fixedSize()
        } else {
            Text(account.name)
                .font(font)
                .lineLimit(1)
                .truncationMode(account.provider.isNamedByEmail ? .middle : .tail)
                .onTapGesture(count: 2) { renaming?.begin(account.id) }
        }
    }
}

struct AccountStatus {
    var refreshing = false
    var notice: String?
    var staleness: String?

    @MainActor @ViewBuilder
    var glyph: some View {
        if refreshing {
            MotionAwareProgressView(controlSize: .mini)
                .accessibilityLabel("Refreshing")
        } else if let notice {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.notice)
                .hoverTooltip(notice)
                .accessibilityLabel(notice)
        } else if let staleness {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .hoverTooltip(staleness)
                .accessibilityLabel(staleness)
        }
    }
}

struct DashboardAccountRows: View {
    let account: DashboardAccount
    var plan: String?
    var isCaptioned = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCaptioned {
                DashboardAccountCaption(account: account, plan: plan)
                    .padding(.bottom, DashboardGrid.captionGap)
            }
            DashboardLineStack(lines: account.lines) { line in
                DashboardMetricRow(model: line.data.dashboardRow())
            }
        }
    }
}
