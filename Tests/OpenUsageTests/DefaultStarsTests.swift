import XCTest
@testable import OpenUsage

@MainActor
final class DefaultStarsTests: XCTestCase {
    func testAnAccountAddedAfterAStarEditStillGetsItsDefaultStars() {
        let app = makeApp()
        let claude = app.add(.claude)
        app.layout.setPinned(false, for: "\(claude.cardID).session")
        XCTAssertEqual(app.layout.pinnedMetricIDs, ["\(claude.cardID).weekly"])

        let codex = app.add(.codex)

        let expected: Set<String> = ["\(claude.cardID).weekly", "\(codex.cardID).session", "\(codex.cardID).weekly"]
        XCTAssertEqual(app.layout.pinnedMetricIDs, expected)

        app.relaunch()
        XCTAssertEqual(app.layout.pinnedMetricIDs, expected)

        app.layout.setPinned(false, for: "\(codex.cardID).session")
        app.relaunch()
        XCTAssertEqual(app.layout.pinnedMetricIDs, ["\(claude.cardID).weekly", "\(codex.cardID).weekly"],
                       "a star the user took off is not put back")
    }

    func testZeroSevenStarsUnderAProviderIDGoToItsFirstAccount() {
        let defaults = isolatedDefaults()
        defaults.set(["claude"], forKey: "openusage.enabledProviders.v1")
        defaults.set(["claude.weekly"], forKey: "openusage.layout.v1.menuBarPins")
        let app = StarsApp(defaults: defaults)

        let first = app.add(.claude)
        let second = app.add(.claude)

        XCTAssertEqual(app.layout.pinnedMetricIDs, [
            "\(first.cardID).weekly", "\(second.cardID).session", "\(second.cardID).weekly"
        ], "the first Claude account takes 0.7.x's stars and the second its default stars")
    }

    private func makeApp() -> StarsApp {
        StarsApp(defaults: isolatedDefaults())
    }

}

@MainActor
private final class StarsApp {
    private let defaults: UserDefaults
    private let vault = InMemoryCredentialVault()
    private(set) var accounts: AccountStore
    private(set) var layout: LayoutStore

    init(defaults: UserDefaults) {
        self.defaults = defaults
        accounts = AccountStore(defaults: defaults, vault: vault)
        layout = LayoutStore(registry: Self.registry(accounts), defaults: defaults)
    }

    @discardableResult
    func add(_ kind: ProviderKind) -> Account {
        let account = accounts.add(kind: kind, label: kind.displayName, credential: .apiKey("key"))
        layout.apply(registry: Self.registry(accounts))
        return account
    }

    func relaunch() {
        accounts = AccountStore(defaults: defaults, vault: vault)
        layout = LayoutStore(registry: Self.registry(accounts), defaults: defaults)
    }

    private static func registry(_ accounts: AccountStore) -> WidgetRegistry {
        WidgetRegistry.from(ProviderCatalog.make(accounts: accounts.accounts, vault: accounts.credentialVault))
    }
}
