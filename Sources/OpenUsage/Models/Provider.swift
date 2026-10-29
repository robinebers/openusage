import Foundation

struct Provider: Identifiable, Hashable {
    let id: String
    let kind: ProviderKind
    var accountLabel: String? = nil
    var organization: String? = nil

    var displayName: String { kind.displayName }
    var icon: String { kind.rawValue }
    var links: [ProviderLink] { kind.links }

    var organizationBillingPage: URL? {
        organization.map { URL(string: "https://github.com/organizations")!.appending(components: $0, "settings", "billing") }
    }

    var accountName: String {
        guard let accountLabel, !accountLabel.isEmpty else { return displayName }
        return accountLabel
    }

    var fullName: String {
        guard let label = labelBesideName else { return displayName }
        return "\(displayName) · \(label)"
    }

    var labelBesideName: String? {
        guard let accountLabel, !accountLabel.isEmpty,
              accountLabel.caseInsensitiveCompare(displayName) != .orderedSame else { return nil }
        return accountLabel
    }
}

struct ProviderLink: Hashable {
    let label: String
    let url: URL
}
