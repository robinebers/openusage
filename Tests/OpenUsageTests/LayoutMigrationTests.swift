import XCTest
@testable import OpenUsage

@MainActor
final class LayoutMigrationTests: XCTestCase {
    func testTheFirstAccountOfAProviderTakesItsZeroSevenStarsHiddenMetricsAndOrder() throws {
        let app = try MigrationApp(defaults: zeroSevenDefaults())

        let claude = app.add(.claude)
        XCTAssertEqual(app.stars(claude), ["weekly"])
        XCTAssertEqual(app.hidden(claude), ["extra", "sonnet"])
        XCTAssertEqual(app.order(claude), ["session", "weekly", "sonnet", "extra", "fable", "rateLimitResets"])

        let codex = app.add(.codex)
        XCTAssertEqual(app.stars(codex), ["session", "weekly"])
        XCTAssertEqual(app.hidden(codex), ["spark", "sparkWeekly"], "a star 0.7.x showed only in the menu bar shows its metric")
        XCTAssertEqual(app.order(codex), ["weekly", "session", "credits", "rateLimitResets", "spark", "sparkWeekly"])

        let secondClaude = app.add(.claude)
        XCTAssertEqual(app.stars(secondClaude), ["session", "weekly"], "a provider's later accounts start with the default stars")
        XCTAssertEqual(app.hidden(secondClaude), [])
    }

    func testStarsOnGoneMetricsFallBackToDefaultsAndNoAccountStartsEmpty() throws {
        let app = try MigrationApp(defaults: zeroSevenDefaults())

        let openRouter = app.add(.openrouter)
        XCTAssertEqual(app.stars(openRouter), ["credits"], "0.7.x's Credits star lands on the restored Credits meter")
        XCTAssertEqual(app.hidden(openRouter), ["keyLimit", "month", "week"])

        let cursor = app.add(.cursor)
        XCTAssertEqual(app.hidden(cursor), ["api", "auto", "grokBot", "last30", "onDemand", "requests", "usage"])
        XCTAssertEqual(app.stars(cursor), ["today", "yesterday"], "0.7.x's stars land on the restored Today and Yesterday rows")

        let grok = app.add(.grok)
        XCTAssertEqual(app.hidden(grok), [], "0.7.x showed only Grok metrics that are gone")
        XCTAssertEqual(app.stars(grok), [], "0.7.x had no Grok stars")

        let ollama = app.add(.ollama)
        XCTAssertEqual(app.stars(ollama), ["monthly"], "0.7.x had Ollama off")
    }

    func testDevinTakesItsZeroSevenHiddenMetrics() throws {
        let defaults = isolatedDefaults()
        try Self.savePlaced(["devin.weekly"], to: defaults)
        defaults.set(["devin"], forKey: "openusage.enabledProviders.v1")
        let app = MigrationApp(defaults: defaults)
        XCTAssertEqual(app.hidden(app.add(.devin)), ["daily", "extra"])
    }

    func testDevinKeepsItsZeroSevenStarsAndOnlyANewAccountTakesTheDefaults() throws {
        let fresh = MigrationApp(defaults: isolatedDefaults())
        XCTAssertEqual(fresh.stars(fresh.add(.devin)), ["daily", "weekly"])

        let untouched = isolatedDefaults()
        try Self.savePlaced(["devin.daily", "devin.weekly", "devin.extra"], to: untouched)
        untouched.set(["devin"], forKey: "openusage.enabledProviders.v1")
        let app = MigrationApp(defaults: untouched)
        XCTAssertEqual(app.stars(app.add(.devin)), [], "0.7.x starred no Devin metric unless the user did")
        XCTAssertEqual(app.stars(app.add(.devin)), ["daily", "weekly"], "a provider's later accounts start with the default stars")

        let starred = isolatedDefaults()
        try Self.savePlaced(["devin.daily", "devin.weekly", "devin.extra"], to: starred)
        starred.set(["devin"], forKey: "openusage.enabledProviders.v1")
        starred.set(["devin.extra"], forKey: "openusage.layout.v1.menuBarPins")
        let starredApp = MigrationApp(defaults: starred)
        XCTAssertEqual(starredApp.stars(starredApp.add(.devin)), ["extra"])
    }

    func testCursorStarsTotalUsageAndTodayWhenZeroSevenSavedNoStars() throws {
        let fresh = MigrationApp(defaults: isolatedDefaults())
        XCTAssertEqual(fresh.stars(fresh.add(.cursor)), ["today", "usage"])

        let untouched = isolatedDefaults()
        try Self.savePlaced(["cursor.usage", "cursor.auto", "cursor.api", "cursor.today"], to: untouched)
        untouched.set(["cursor"], forKey: "openusage.enabledProviders.v1")
        let app = MigrationApp(defaults: untouched)
        XCTAssertEqual(app.stars(app.add(.cursor)), ["today", "usage"], "an upgrader who never saved stars takes the new defaults")
    }

    func testAnEmptyStarListStaysEmpty() {
        let defaults = isolatedDefaults()
        defaults.set(["claude"], forKey: "openusage.enabledProviders.v1")
        defaults.set([String](), forKey: "openusage.layout.v1.menuBarPins")
        let app = MigrationApp(defaults: defaults)
        XCTAssertEqual(app.stars(app.add(.claude)), [], "0.7.x had every star taken off")
    }

    func testProvidersTakeZeroSevensOrderAndTheUsersLaterOrderWins() throws {
        let app = try MigrationApp(defaults: zeroSevenDefaults())

        app.add(.grok)
        app.add(.ollama)
        app.add(.cursor)
        app.add(.claude)
        XCTAssertEqual(app.families, ["claude", "cursor", "grok", "ollama"])

        XCTAssertTrue(app.layout.reorderFamily(dragged: "grok", target: "claude"))
        app.add(.codex)
        XCTAssertEqual(app.families, ["grok", "claude", "codex", "cursor", "ollama"])

        app.relaunch()
        XCTAssertEqual(app.families, ["grok", "claude", "codex", "cursor", "ollama"])
    }

    func testZeroSevenKeysStayByteIdenticalThroughTheMoveAndLaterEdits() throws {
        let defaults = try zeroSevenDefaults()
        let before = Self.v1Values(defaults)
        let app = MigrationApp(defaults: defaults)

        let claude = app.add(.claude)
        app.add(.codex)
        app.layout.setPinned(true, for: "\(claude.cardID).session")
        app.layout.setMetricEnabled("\(claude.cardID).weekly", false)
        XCTAssertTrue(app.layout.reorderFamily(dragged: "codex", target: "claude"))
        XCTAssertTrue(app.layout.reorderMetric(dragged: "\(claude.cardID).fable", target: "\(claude.cardID).session", in: claude.cardID))
        XCTAssertTrue(app.layout.undo())
        app.relaunch()

        XCTAssertEqual(Self.v1Values(defaults), before)
    }

    func testASecondRunChangesNothingAndLaterEditsWin() throws {
        let defaults = try zeroSevenDefaults()
        let app = MigrationApp(defaults: defaults)
        let claude = app.add(.claude)
        let saved = defaults.data(forKey: "openusage.layout.v2")

        app.layout.apply(registry: app.layout.registry)
        app.relaunch()
        XCTAssertEqual(app.stars(claude), ["weekly"])
        XCTAssertEqual(app.hidden(claude), ["extra", "sonnet"])
        XCTAssertEqual(defaults.data(forKey: "openusage.layout.v2"), saved, "a second run writes nothing")

        app.layout.setPinned(false, for: "\(claude.cardID).weekly")
        app.layout.setMetricEnabled("\(claude.cardID).sonnet", true)
        app.relaunch()
        XCTAssertEqual(app.stars(claude), [])
        XCTAssertEqual(app.hidden(claude), ["extra"])
    }

    /// Shaped like a real 0.7.16 layout: a second Claude account's `@` id beside bare ids, a star on a
    /// metric it did not place, stars on spend rows that are gone, and a provider with no account today.
    private func zeroSevenDefaults() throws -> UserDefaults {
        let defaults = isolatedDefaults()
        let claude = "claude@aaaa1111"
        try Self.savePlaced([
            "\(claude).session", "\(claude).weekly", "\(claude).fable", "\(claude).rateLimitResets",
            "\(claude).today", "\(claude).trend",
            "codex.weekly", "codex.credits", "codex.rateLimitResets", "codex.trend",
            "cursor.credits", "cursor.today", "cursor.yesterday",
            "grok.trend",
            "devin.weekly",
            "openrouter.credits", "openrouter.balance", "openrouter.today",
            "claude@bbbb2222.session", "claude@bbbb2222.weekly", "claude@bbbb2222.sonnet", "claude@bbbb2222.extra"
        ], to: defaults)
        defaults.set(try JSONEncoder().encode([claude, "codex", "cursor", "devin", "grok"]), forKey: "openusage.layout.v1.providerOrder")
        defaults.set(try JSONEncoder().encode([
            claude: ["session", "weekly", "sonnet", "extra", "fable", "rateLimitResets", "today", "trend"].map { "\(claude).\($0)" },
            "codex": ["weekly", "session", "credits", "rateLimitResets", "spark", "sparkWeekly", "trend"].map { "codex.\($0)" }
        ]), forKey: "openusage.layout.v1.metricOrderByProvider")
        defaults.set(["\(claude).weekly", "codex.session", "codex.weekly", "cursor.today", "cursor.yesterday", "openrouter.credits",
                      "ollama.session"], forKey: "openusage.layout.v1.menuBarPins")
        defaults.set([claude, "codex", "cursor", "grok", "openrouter"], forKey: "openusage.enabledProviders.v1")
        defaults.set(try JSONEncoder().encode(["codex.weekly"]), forKey: "openusage.layout.v1.seededDefaults")
        defaults.set(["cursor"], forKey: "openusage.layout.v1.expandedProviders")
        return defaults
    }

    private static func savePlaced(_ ids: [String], to defaults: UserDefaults) throws {
        let placed = ids.map { ["id": UUID().uuidString, "descriptorID": $0] }
        defaults.set(try JSONSerialization.data(withJSONObject: placed), forKey: "openusage.layout.v1")
    }

    private static func v1Values(_ defaults: UserDefaults) -> [String: NSObject] {
        defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("openusage.layout.v1") }
            .compactMapValues { $0 as? NSObject }
    }
}

@MainActor
private final class MigrationApp {
    private let defaults: UserDefaults
    private let accounts: AccountStore
    private(set) var layout: LayoutStore

    init(defaults: UserDefaults) {
        self.defaults = defaults
        accounts = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        layout = LayoutStore(registry: Self.registry(accounts), defaults: defaults)
    }

    @discardableResult
    func add(_ kind: ProviderKind) -> Account {
        let account = accounts.add(kind: kind, label: kind.displayName, credential: .apiKey("key"))
        layout.apply(registry: Self.registry(accounts))
        return account
    }

    func relaunch() {
        layout = LayoutStore(registry: Self.registry(accounts), defaults: defaults)
    }

    func stars(_ account: Account) -> [String] {
        layout.registry.descriptors(for: account.cardID).filter { layout.isPinned($0.id) }.map(\.key).sorted()
    }

    func hidden(_ account: Account) -> [String] {
        layout.registry.descriptors(for: account.cardID).filter { !layout.isMetricEnabled($0.id) }.map(\.key).sorted()
    }

    func order(_ account: Account) -> [String] {
        layout.orderedSupportedMetrics(for: account.cardID).map(\.key)
    }

    var families: [String] {
        var families: [String] = []
        for kind in layout.orderedProviders().map(\.kind.rawValue) where !families.contains(kind) {
            families.append(kind)
        }
        return families
    }

    private static func registry(_ accounts: AccountStore) -> WidgetRegistry {
        WidgetRegistry.from(ProviderCatalog.make(accounts: accounts.accounts, vault: accounts.credentialVault))
    }
}
