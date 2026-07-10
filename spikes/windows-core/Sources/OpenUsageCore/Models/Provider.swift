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
}

/// One external quick-link button on a provider card: a label and a URL opened in the default browser.
struct ProviderLink: Hashable {
    let label: String
    let url: String
}
