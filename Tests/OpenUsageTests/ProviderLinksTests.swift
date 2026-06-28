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
        XCTAssertTrue(provider([.init(label: "", url: "")]).visibleLinks.isEmpty)
    }

    func testKeepsValidHttpsAndHttp() {
        let links = [
            ProviderLink(label: "Status", url: "https://status.example.com/"),
            ProviderLink(label: "HTTP", url: "http://example.com/dashboard")
        ]
        let visible = provider(links).visibleLinks
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].label, "Status")
        XCTAssertEqual(visible[0].url, "https://status.example.com/")
        XCTAssertEqual(visible[1].url, "http://example.com/dashboard")
    }

    func testDropsEmptyLabelOrUrl() {
        let links = [
            ProviderLink(label: "", url: "https://example.com/"),
            ProviderLink(label: "No URL", url: ""),
            ProviderLink(label: "Both", url: "https://example.com/")
        ]
        XCTAssertEqual(provider(links).visibleLinks.map(\.label), ["Both"])
    }

    func testDropsWhitespaceOnlyLabelOrUrl() {
        let links = [
            ProviderLink(label: "   ", url: "https://example.com/"),
            ProviderLink(label: "Spaces", url: "   "),
            ProviderLink(label: "Kept", url: "https://example.com/")
        ]
        XCTAssertEqual(provider(links).visibleLinks.map(\.label), ["Kept"])
    }

    func testTrimsLabelAndUrl() {
        let visible = provider([.init(label: "  Status  ", url: "  https://status.example.com/  ")]).visibleLinks
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].label, "Status")
        XCTAssertEqual(visible[0].url, "https://status.example.com/")
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
}
