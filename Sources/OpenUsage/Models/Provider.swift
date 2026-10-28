import Foundation

struct Provider: Identifiable, Hashable {
    let id: String
    let kind: ProviderKind
    var accountLabel: String? = nil

    var displayName: String { kind.displayName }
    var icon: String { kind.rawValue }
    var links: [ProviderLink] { kind.links }

    var accountName: String {
        guard let accountLabel, !accountLabel.isEmpty else { return displayName }
        return accountLabel
    }

    var fullName: String {
        guard let accountLabel, !accountLabel.isEmpty else { return displayName }
        return "\(displayName) · \(accountLabel)"
    }
}

struct ProviderLink: Hashable {
    let label: String
    let url: URL
}
