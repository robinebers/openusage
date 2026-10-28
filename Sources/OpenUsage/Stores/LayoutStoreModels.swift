/// A provider and a list of its metrics in the provider's custom order. Drives the grouped dashboard
/// list, the Accounts detail and the menu-bar pin grouping.
struct ProviderMetrics: Identifiable {
    let provider: Provider
    let metrics: [WidgetDescriptor]
    var id: String { provider.id }
}

/// Tone for the Accounts screen's transient pill (`PopoverState.accountsNotice`): green success or
/// orange denial.
enum CustomizationNoticeTone {
    case positive
    case notice
}

/// The message + tone carried by the Accounts pill's `TransientNotice`, so its two fields clear together.
struct CustomizationNoticeContent {
    var message: String
    var tone: CustomizationNoticeTone
}

/// An immutable capture of every piece of layout state a user action can change — the unit the undo
/// stack stores. Rather than record a bespoke inverse per action type (remove vs. reorder vs. pin),
/// undo snapshots this whole slice before each change and restores it wholesale, so every action kind
/// is undoable through one code path and the restore is always exact (interlocking state — order,
/// enabled metrics, and pins all move together — can't drift out of sync).
///
/// Equatable so the store can skip pushing a snapshot when an action turned out to be a no-op.
struct LayoutSnapshot: Equatable {
    let hiddenMetricIDs: Set<String>
    let providerOrder: [String]
    let metricOrderByProvider: [String: [String]]
    let pinnedMetricIDs: Set<String>
}
