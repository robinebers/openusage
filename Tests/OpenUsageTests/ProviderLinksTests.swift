import XCTest
@testable import OpenUsage

/// `Provider.visibleLinks` is the boundary that keeps a malformed link entry from shipping a dead or
/// no-op button on the card. It mirrors the legacy Tauri `visibleLinks` filter: trim, require a
/// non-empty label and URL, and accept `http(s)` schemes only.
final class ProviderLinksTests: XCTestCase {
    private func provider(_ links: [ProviderLink]) -> Provider {
        Provider(id: "test", displayName: "Test", icon: .providerMark("test"), links: links)
    }

    func testNoLinksYieldsEmptyVisibleLinks() {
        XCTAssertTrue(provider([]).visibleLinks.isEmpty)
    }

    func testKeepsValidHttpsAndHttp() {
        let links = [
            ProviderLink(label: "Status", url: "https://status.example.com/"),
            ProviderLink(label: "HTTP", url: "http://example.com/dashboard")
        ]
        XCTAssertEqual(provider(links).visibleLinks, links)
    }

    func testRejectsEmptyOrWhitespaceOnlyFields() {
        let invalidLinks = [
            ProviderLink(label: "", url: "https://example.com/"),
            ProviderLink(label: "No URL", url: ""),
            ProviderLink(label: "   ", url: "https://example.com/"),
            ProviderLink(label: "Spaces", url: "   ")
        ]
        for link in invalidLinks {
            XCTAssertTrue(provider([link]).visibleLinks.isEmpty, "\(link)")
        }
    }

    func testTrimsLabelAndUrl() {
        XCTAssertEqual(
            provider([.init(label: "  Status  ", url: "  https://status.example.com/  ")]).visibleLinks,
            [ProviderLink(label: "Status", url: "https://status.example.com/")]
        )
    }

    func testRejectsNonHttpSchemes() {
        let links = [
            ProviderLink(label: "FTP", url: "ftp://example.com/"),
            ProviderLink(label: "JS", url: "javascript:alert(1)"),
            ProviderLink(label: "Mail", url: "mailto:a@b.com"),
            ProviderLink(label: "No scheme", url: "example.com"),
            ProviderLink(label: "Kept", url: "https://example.com/")
        ]
        XCTAssertEqual(provider(links).visibleLinks.map(\.label), ["Kept"])
    }

    func testMixedSetKeepsOnlyValid() {
        let links = [
            ProviderLink(label: "Status", url: "https://status.anthropic.com/"),
            ProviderLink(label: "", url: "https://console.anthropic.com/"),
            ProviderLink(label: "Bad", url: "ftp://nope"),
            ProviderLink(label: "Console", url: "https://console.anthropic.com/")
        ]
        XCTAssertEqual(provider(links).visibleLinks.map(\.label), ["Status", "Console"])
    }

    /// Every installed provider ships at most two quick links with standard labels.
    @MainActor
    func testInstalledProvidersRespectQuickLinkCap() {
        let allowed = Set(["Status", "Dashboard", "API Keys", "Usage", "Activity", "Credits"])
        let suiteName = "ProviderLinksTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let providers = ProviderCatalog.make(defaults: defaults)
        for runtime in providers {
            let links = runtime.provider.visibleLinks
            XCTAssertLessThanOrEqual(
                links.count, 2,
                "\(runtime.provider.displayName) has \(links.count) quick links"
            )
            for link in links {
                XCTAssertTrue(
                    allowed.contains(link.label),
                    "\(runtime.provider.displayName) link label '\(link.label)' is non-standard"
                )
            }
        }
    }
}
