import SwiftUI

/// One provider on the dashboard: its header above its card. Every card is drawn the same way, however
/// many accounts it holds: the header is the provider's logo and name, and each account in the card is
/// captioned with its name, status glyph and plan over its rows. Static but for the captions' status
/// tooltips and the header the dashboard supplies, with its copy button and the provider's drag: it
/// adds menus and drags around the section, and the share image draws the section as it is.
struct DashboardProviderSection<Header: View, Account: View>: View {
    let family: DashboardFamily
    @ViewBuilder var header: Header
    /// An account's block in the card: its caption over its rows.
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
    /// The section with the provider's plain header, without a copy button, as in the share image and
    /// the drag previews.
    init(family: DashboardFamily, @ViewBuilder account: @escaping (DashboardAccount) -> Account) {
        self.init(family: family, header: { DashboardProviderHeader(provider: family.provider) }, account: account)
    }
}

/// The line above a provider's card: the logo where the rows' labels start, then 8 pt to the provider's
/// name, centred on the line. With `onCopyScreenshot`, a Copy Screenshot button sits at the trailing
/// edge, where the rows' resets end, revealed while the pointer rests on the header.
struct DashboardProviderHeader: View {
    let provider: Provider
    var onCopyScreenshot: (() -> Bool)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            ProviderIcon(id: provider.icon, side: DashboardGrid.iconSize, inset: 0.04)
                .padding(.trailing, DashboardGrid.columnGap)
            Text(provider.displayName)
                .font(DashboardGrid.headerFont)
                .lineLimit(1)
            if let onCopyScreenshot {
                Spacer(minLength: DashboardGrid.columnGap)
                CopyFeedbackButton(
                    accessibilityLabel: "Copy \(provider.displayName) Screenshot",
                    isRevealed: isHovered,
                    action: onCopyScreenshot
                )
            }
        }
        .padding(.horizontal, DashboardGrid.cardPadding + DashboardGrid.inset)
        .frame(height: DashboardGrid.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

/// An account's caption inside its provider's card: its name in Subheadline semibold at the
/// left and its plan as plain Subheadline at the right, both secondary — never a badge. The name
/// truncates (an email keeps its domain) and the plan never does.
struct DashboardAccountCaption: View {
    let account: DashboardAccount
    var plan: String?
    var status = AccountStatus()

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            AccountName(account: account, font: DashboardGrid.captionFont)
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

/// An account's name on its caption. A double-click opens
/// the inline rename in its place, the same as the right-click Rename.
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

/// An account's refresh state, after its name: a spinner while it refreshes, a warning when the refresh
/// failed, a clock when its reading is stale. Nothing while all is well. A warning or clock explains
/// itself on hover, as the right-click menu does; the spinner says nothing.
struct AccountStatus {
    var refreshing = false
    var notice: String?
    /// How old the reading is, once it is stale.
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

/// An account's caption over its rows, at rest: what the share image and the drag previews draw.
struct DashboardAccountRows: View {
    let account: DashboardAccount
    var plan: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardAccountCaption(account: account, plan: plan)
            ForEach(account.lines) { line in
                DashboardMetricRow(model: line.data.dashboardRow())
            }
        }
    }
}
