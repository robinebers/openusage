import Foundation

/// A provider metric's identity and presentation template. Live provider lines supply the values;
/// `sample` carries stable display metadata such as title, icon, kind, and descriptor opt-ins.
struct WidgetDescriptor: Identifiable, Hashable {
    let id: String                 // "claude@1a2b3c4d.session"
    let providerID: String
    let providerKind: ProviderKind
    /// The metric's name on every account of its provider: "session".
    let key: String
    let metricLabel: String
    let sample: WidgetData
    /// The scalars this metric contributes to the `openusage` command's limits JSON; empty for
    /// presentation-only rows.
    var limitResources: [LimitResourceDescriptor] = []
    /// Starred into the menu bar the first time its account shows up.
    var isPinnedByDefault = false

    init(provider: Provider, key: String, metricLabel: String, sample: WidgetData) {
        id = "\(provider.id).\(key)"
        providerID = provider.id
        providerKind = provider.kind
        self.key = key
        self.metricLabel = metricLabel
        self.sample = sample
    }

    /// "claude.session" on every Claude account. Telemetry reports these, so PostHog keeps one id per
    /// provider instead of one per account.
    var kindScopedKey: String { "\(providerKind.rawValue).\(key)" }

    func pinnedByDefault() -> WidgetDescriptor {
        var copy = self
        copy.isPinnedByDefault = true
        return copy
    }

    /// The metric's single display name.
    var title: String { sample.title }

    static func == (lhs: WidgetDescriptor, rhs: WidgetDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
