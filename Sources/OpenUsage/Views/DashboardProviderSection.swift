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
            .padding(.horizontal, DashboardGrid.cardPadding)
            .padding(.top, DashboardGrid.cardTopPadding)
            .padding(.bottom, DashboardGrid.cardBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

extension DashboardProviderSection where Header == DashboardProviderHeader {
    init(family: DashboardFamily, @ViewBuilder account: @escaping (DashboardAccount) -> Account) {
        self.init(family: family, header: { DashboardProviderHeader(family: family) }, account: account)
    }
}

struct DashboardProviderHeader: View {
    let family: DashboardFamily
    var onCopyScreenshot: (() -> Bool)?

    @State private var isHovered = false
    @State private var copied = false

    private var provider: Provider { family.provider }

    var body: some View {
        HStack(spacing: 0) {
            Text(provider.displayName)
                .font(DashboardGrid.headerFont)
                .lineLimit(1)
            Spacer(minLength: DashboardGrid.columnGap)
            logoOrCopy
        }
        .padding(.horizontal, DashboardGrid.cardPadding)
        .frame(height: DashboardGrid.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered || copied)
    }
}

struct DashboardAccountCaption: View {
    let account: DashboardAccount
    var plan: String?
    var status = AccountStatus()
    var hasSiblingAccounts = false

    @Environment(AccountRenameStore.self) private var renaming: AccountRenameStore?

    /// A sole default-named account sits under its provider's name. Siblings need separate drag handles.
    private var showsName: Bool {
        hasSiblingAccounts || account.provider.labelBesideName != nil || renaming?.edit?.providerID == account.id
    }

    @ViewBuilder
    var body: some View {
        if showsName || plan != nil || status.isShowing {
            caption.padding(.bottom, DashboardGrid.captionGap)
        }
    }

    private var caption: some View {
        HStack(spacing: Theme.Spacing.s) {
            if showsName {
                AccountNameLabel(account: account, font: DashboardGrid.captionFont)
                    .foregroundStyle(.secondary)
            }
            status.glyph
            Spacer(minLength: DashboardGrid.columnGap)
            if let plan {
                PlanBadge(plan: plan)
            }
        }
        .frame(height: DashboardGrid.captionHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(plan)
            .font(DashboardGrid.planFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, DashboardGrid.planPadding)
            .frame(height: DashboardGrid.captionHeight)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
    /// Opens the account's page, the same as Fix on Priority.
    var onFix: (() -> Void)?

    var isShowing: Bool { refreshing || notice != nil || staleness != nil }

    @MainActor @ViewBuilder
    var glyph: some View {
        if refreshing {
            MotionAwareProgressView(controlSize: .mini)
                .accessibilityLabel("Refreshing")
        } else if let notice {
            Button { onFix?() } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
            }
            .buttonStyle(.plain)
            .disabled(onFix == nil)
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
    var hasSiblingAccounts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardAccountCaption(account: account, plan: plan, hasSiblingAccounts: hasSiblingAccounts)
            DashboardLineStack(account: account) { line in
                DashboardMetricRow(model: line.data.dashboardRow())
            }
        }
    }
}
