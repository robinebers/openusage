import Foundation

/// A data source that can register widgets it knows how to feed.
struct Provider: Identifiable, Hashable {
    let id: String
    let displayName: String
    let icon: IconSource
    /// Per-provider quick links (e.g. "Status", "Console") shown as buttons in the card's expanded area.
    /// Declared inline by each provider; mirrors the legacy Tauri `PluginMeta.links`. Empty by default so
    /// providers without links and the existing `Provider(id:displayName:icon:)` call sites need no change.
    let links: [ProviderLink]

    init(id: String, displayName: String, icon: IconSource, links: [ProviderLink] = []) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.links = links
    }

    /// Links safe to render: trimmed, non-empty label and URL, and an `http(s)` scheme only. Mirrors the
    /// legacy `visibleLinks` filter so a malformed entry never ships a dead or no-op button.
    var visibleLinks: [ProviderLink] {
        links.compactMap { link in
            let label = link.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  !url.isEmpty,
                  url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
            return ProviderLink(label: label, url: url)
        }
    }

    /// The account half of a multi-account provider's name: `displayName` with its leading agent
    /// prefix removed, so "Claude: Acme (jane@example.com)" reads "Acme (jane@example.com)".
    ///
    /// Two prefix shapes exist: swap and Codex accounts use "Agent: …", and Claude Desktop
    /// organizations use an em dash between spaces instead. Either is recognized, but only when
    /// the words before it are the provider's own agent, matched against the base half of its id
    /// ("claude" for `claude@3ac4b63e`). That keeps separators inside an account label alone: a
    /// workspace aliased "Work: Main" still yields "Work: Main (…)" rather than losing its first word.
    ///
    /// `nil` whenever there is no agent prefix to drop, which covers every single-account provider
    /// ("Cursor", and a lone "Claude").
    var accountLabel: String? {
        let baseID = String(id.split(separator: "@").first ?? Substring(id)).lowercased()
        for separator in Self.agentSeparators {
            guard let range = displayName.range(of: separator) else { continue }
            guard displayName[displayName.startIndex..<range.lowerBound].lowercased() == baseID else { continue }
            let label = String(displayName[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? nil : label
        }
        return nil
    }

    /// Colon form first: an alias may itself contain an em dash, and the colon is the one that
    /// follows the agent in that case.
    private static let agentSeparators = [": ", " \u{2014} "]

    /// What a card header calls this provider. A multi-account provider's cards all repeat the same
    /// agent prefix while the provider mark beside the name already says which agent it is, so the
    /// header drops it and spends that width on the account. "Hide Emails" then masks any address
    /// left in the name. Single-account providers carry no prefix and read the same either way.
    func headerName(hidingEmails: Bool = false) -> String {
        let name = accountLabel ?? displayName
        return hidingEmails ? EmailMask.mask(name) : name
    }

    /// What every other visible surface calls this provider (Customize, menus, the Total Spend
    /// legend, share cards, notifications). Only Hide Emails applies there; the agent-name setting
    /// is scoped to card headers, where the provider mark already names the agent.
    func visibleName(hidingEmails: Bool) -> String {
        hidingEmails ? EmailMask.mask(displayName) : displayName
    }
}

/// One external quick-link button on a provider card: a label and a URL opened in the default browser.
struct ProviderLink: Hashable {
    let label: String
    let url: String
}
