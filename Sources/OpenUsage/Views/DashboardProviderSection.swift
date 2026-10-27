import SwiftUI

/// One provider on the dashboard: its header above its card. Every card is drawn the same way, however
/// many accounts it holds: the header is the provider's logo and name, and each account in the card is
/// captioned with its name, status glyph and plan over its rows. Static but for the captions' status
/// tooltips: the dashboard adds menus and drags around it, and the share image draws it as it is.
struct DashboardProviderSection<Account: View>: View {
    let family: DashboardFamily
    /// Wraps the header, so the dashboard can attach the provider's drag gesture to it.
    var handle: (AnyView) -> AnyView = { $0 }
    /// An account's block in the card: its caption over its rows.
    @ViewBuilder var account: (DashboardAccount) -> Account

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardGrid.headerGap) {
            handle(AnyView(header))
            VStack(alignment: .leading, spacing: DashboardGrid.accountSpacing) {
                ForEach(family.accounts) { account($0) }
            }
            .padding(DashboardGrid.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    var header: DashboardProviderHeader {
        DashboardProviderHeader(provider: family.provider)
    }
}

/// The line above a provider's card: the logo where the rows' labels start, then 8 pt to the provider's
/// name, centred on the line.
struct DashboardProviderHeader: View {
    let provider: Provider

    var body: some View {
        HStack(spacing: 0) {
            ProviderIcon(id: provider.icon, inset: 0.04)
                .frame(width: DashboardGrid.iconSize, height: DashboardGrid.iconSize)
                .padding(.trailing, DashboardGrid.columnGap)
            Text(provider.displayName)
                .font(DashboardGrid.headerFont)
                .lineLimit(1)
        }
        .padding(.horizontal, DashboardGrid.cardPadding + DashboardGrid.inset)
        .frame(height: DashboardGrid.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
