import Foundation

/// A data source that can register widgets it knows how to feed.
struct Provider: Identifiable, Hashable {
    let id: String
    let kind: ProviderKind
    var accountLabel: String? = nil

    var displayName: String { kind.displayName }
    /// The provider mark drawn beside the name, which names its SVG.
    var icon: String { kind.rawValue }
    /// The provider's quick links (e.g. "Status Page"), listed last in the dashboard card's right-click menu.
    var links: [ProviderLink] { kind.links }

    /// The account's own name, or the provider's when it has none.
    var accountName: String {
        guard let accountLabel, !accountLabel.isEmpty else { return displayName }
        return accountLabel
    }

    /// "Claude · AM1": the provider and the account's name, for a menu item or dialog that has one line to
    /// tell accounts of the same provider apart.
    var fullName: String {
        guard let accountLabel, !accountLabel.isEmpty else { return displayName }
        return "\(displayName) · \(accountLabel)"
    }
}

/// One external quick link in a provider card's menu: a label and a URL opened in the default browser.
struct ProviderLink: Hashable {
    let label: String
    let url: URL
}
