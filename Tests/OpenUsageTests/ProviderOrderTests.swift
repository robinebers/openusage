import XCTest
@testable import OpenUsage

@MainActor
final class ProviderOrderTests: XCTestCase {
    func testNewProvidersGoToTheBottomInTheOrderTheyWereAdded() {
        let app = makeApp()
        app.add(.claude)
        app.add(.codex)

        app.add(.grok)
        app.add(.cursor)
        app.add(.antigravity)

        let expected = ["claude", "codex", "grok", "cursor", "antigravity"]
        XCTAssertEqual(app.accountsScreenFamilies, expected)
        XCTAssertEqual(app.dashboardFamilies, expected)
    }

    func testNewAccountGoesToTheBottomOfItsProvider() {
        let app = makeApp()
        let firstClaude = app.add(.claude)
        let codex = app.add(.codex)
        let grok = app.add(.grok)
        XCTAssertTrue(app.layout.reorderFamily(dragged: "grok", target: "codex"))

        let secondClaude = app.add(.claude)

        XCTAssertEqual(
            app.accountsScreen,
            [firstClaude.cardID, secondClaude.cardID, grok.cardID, codex.cardID]
        )
        XCTAssertEqual(app.dashboard, [
            ["claude": [firstClaude.cardID, secondClaude.cardID]],
            ["grok": [grok.cardID]],
            ["codex": [codex.cardID]],
        ])
    }

    func testASecondAccountJoinsItsProviderWithoutADrag() {
        let app = makeApp()
        let firstClaude = app.add(.claude)
        let codex = app.add(.codex)
        let secondClaude = app.add(.claude)

        let accounts = [firstClaude.cardID, secondClaude.cardID, codex.cardID]
        let dashboard = [["claude": [firstClaude.cardID, secondClaude.cardID]], ["codex": [codex.cardID]]]
        XCTAssertEqual(app.accountsScreen, accounts)
        XCTAssertEqual(app.dashboard, dashboard)

        app.relaunch()

        XCTAssertEqual(app.accountsScreen, accounts)
        XCTAssertEqual(app.dashboard, dashboard)
    }

    func testAnAccountKeepsItsPlaceWhenItsProvidersFirstAccountIsRemoved() {
        let app = makeApp()
        let firstClaude = app.add(.claude)
        let codex = app.add(.codex)
        let secondClaude = app.add(.claude)

        app.remove(firstClaude)

        XCTAssertEqual(app.accountsScreen, [secondClaude.cardID, codex.cardID])
        XCTAssertEqual(app.dashboard, [["claude": [secondClaude.cardID]], ["codex": [codex.cardID]]])
    }

    func testAccountsStayGroupedByProviderWhenDragged() {
        let app = makeApp()
        let firstClaude = app.add(.claude)
        let codex = app.add(.codex)
        let secondClaude = app.add(.claude)

        XCTAssertFalse(app.layout.reorderProvider(dragged: codex.cardID, target: secondClaude.cardID))
        XCTAssertEqual(app.accountsScreen, [firstClaude.cardID, secondClaude.cardID, codex.cardID])

        XCTAssertTrue(app.layout.reorderProvider(dragged: secondClaude.cardID, target: firstClaude.cardID))
        XCTAssertEqual(app.accountsScreen, [secondClaude.cardID, firstClaude.cardID, codex.cardID])
        XCTAssertEqual(app.dashboard, [["claude": [secondClaude.cardID, firstClaude.cardID]], ["codex": [codex.cardID]]])
    }

    func testProviderRemovedAndAddedBackGoesToTheBottom() {
        let app = makeApp()
        let claude = app.add(.claude)
        app.add(.codex)
        app.add(.grok)

        app.remove(claude)
        app.add(.claude)

        XCTAssertEqual(app.accountsScreenFamilies, ["codex", "grok", "claude"])
        XCTAssertEqual(app.dashboardFamilies, ["codex", "grok", "claude"])
    }

    func testSavedOrderAndNewProvidersSurviveRelaunch() {
        let app = makeApp()
        app.add(.claude)
        app.add(.codex)
        XCTAssertTrue(app.layout.reorderFamily(dragged: "codex", target: "claude"))
        app.add(.grok)
        app.add(.cursor)

        app.relaunch()

        let expected = ["codex", "claude", "grok", "cursor"]
        XCTAssertEqual(app.accountsScreenFamilies, expected)
        XCTAssertEqual(app.dashboardFamilies, expected)
    }

    private func makeApp() -> OrderingApp {
        let defaults = isolatedDefaults()
        return OrderingApp(defaults: defaults)
    }
}

@MainActor
private final class OrderingApp {
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

    func remove(_ account: Account) {
        accounts.remove(account.id)
        layout.apply(registry: Self.registry(accounts))
    }

    func relaunch() {
        accounts = AccountStore(defaults: defaults, vault: vault)
        layout = LayoutStore(registry: Self.registry(accounts), defaults: defaults)
    }

    var accountsScreen: [String] { layout.orderedProviders().map(\.id) }

    var accountsScreenFamilies: [String] {
        var families: [String] = []
        for id in layout.orderedProviders().map(\.kind.rawValue) where !families.contains(id) {
            families.append(id)
        }
        return families
    }

    var dashboard: [[String: [String]]] {
        DashboardFamily.make(groups: layout.displayGroups) { DashboardLine(descriptor: $0, data: $0.sample) }
            .map { [$0.id: $0.accounts.map(\.id)] }
    }

    var dashboardFamilies: [String] { dashboard.flatMap(\.keys) }

    private static func registry(_ accounts: AccountStore) -> WidgetRegistry {
        WidgetRegistry.from(ProviderCatalog.make(accounts: accounts.accounts, vault: accounts.credentialVault))
    }
}
