import XCTest
@testable import OpenUsage

/// Default stars belong to an account the first time it is seen: an edit to one account's stars does
/// not cost a later account its defaults, a relaunch reseeds nothing, and pins saved under the old
/// family-wide ids do not stand in for an account's own.
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

    func testPinsSavedUnderTheOldFamilyIDsDoNotStandInForAnAccountsOwn() {
        let defaults = isolatedDefaults()
        LayoutPersistence(defaults: defaults, storageKey: "openusage.layout.v1").savePins(["claude.session", "claude.weekly"])
        let app = StarsApp(defaults: defaults)

        let account = app.add(.claude)

        XCTAssertEqual(app.layout.pinnedMetricIDs, ["\(account.cardID).session", "\(account.cardID).weekly"])
    }

    private func makeApp() -> StarsApp {
        StarsApp(defaults: isolatedDefaults())
    }

}

/// The account and layout wiring `AppContainer` does, without the data store.
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
