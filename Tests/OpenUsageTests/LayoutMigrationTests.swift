import XCTest
@testable import OpenUsage

@MainActor
final class LayoutMigrationTests: XCTestCase {
    func testTheFirstAccountOfAProviderTakesItsZeroSevenHiddenMetricsAndOrder() throws {
        let app = try MigrationApp(defaults: zeroSevenDefaults())

        let claude = app.add(.claude)
        XCTAssertEqual(app.hidden(claude), ["extra", "sonnet"])
        XCTAssertEqual(app.order(claude), ["session", "weekly", "sonnet", "extra", "fable", "rateLimitResets"])

        let codex = app.add(.codex)
        XCTAssertEqual(app.hidden(codex), ["last30", "spark", "sparkWeekly", "today", "yesterday"],
                       "a star 0.7.x showed only in the menu bar shows its metric")
        XCTAssertEqual(app.order(codex), ["weekly", "session", "credits", "rateLimitResets", "spark", "sparkWeekly",
                                          "creditLimit", "today", "yesterday", "last30"])

        let secondClaude = app.add(.claude)
        XCTAssertEqual(app.order(secondClaude), ["session", "weekly", "sonnet", "fable", "extra", "rateLimitResets"],
                       "a provider's later accounts start in declaration order")
        XCTAssertEqual(app.hidden(secondClaude), [], "a provider's later accounts start with every metric shown")
    }

    func testZeroSevenHidingSpeaksOnlyForMetricsItHad() throws {
        let app = try MigrationApp(defaults: zeroSevenDefaults())
        XCTAssertEqual(app.hidden(app.add(.grok)), [], "0.7.x showed only Grok metrics that are gone, so no account starts empty")
        XCTAssertEqual(app.hidden(app.add(.ollama)), [], "0.7.x had Ollama off")
    }

    func testADisabledZeroSevenAccountGivesNoLayout() throws {
        let defaults = isolatedDefaults()
        defaults.set(try JSONEncoder().encode(["claude", "claude@aaaa1111"]), forKey: "openusage.layout.v1.providerOrder")
        defaults.set(try JSONEncoder().encode([
            "claude": ["claude.fable", "claude.weekly"],
            "claude@aaaa1111": ["claude@aaaa1111.sonnet", "claude@aaaa1111.session"],
        ]), forKey: "openusage.layout.v1.metricOrderByProvider")
        defaults.set(["claude@aaaa1111"], forKey: "openusage.enabledProviders.v1")
        let app = MigrationApp(defaults: defaults)
        XCTAssertEqual(app.order(app.add(.claude)).prefix(2), ["sonnet", "session"],
                       "the layout comes from the account 0.7.x had on, not the one it listed first")
    }

    func testAProviderOffInZeroSevenTakesNoLayout() throws {
        let app = try MigrationApp(defaults: zeroSevenDefaults())
        let ollama = app.add(.ollama)
        XCTAssertEqual(app.order(ollama).prefix(3), ["session", "weekly", "monthly"])
    }

    func testDisabledAccountDoesNotMoveItsProviderAheadOfAnEnabledAccountOnUpgrade() throws {
        let savedOrder = try JSONEncoder().encode(["claude", "codex", "claude@aaaa1111"])
        let signInOrders: [[ProviderKind]] = [[.claude, .codex], [.codex, .claude]]
        for signInOrder in signInOrders {
            let defaults = isolatedDefaults()
            defaults.set(savedOrder, forKey: "openusage.layout.v1.providerOrder")
            defaults.set(["codex", "claude@aaaa1111"], forKey: "openusage.enabledProviders.v1")
            let app = MigrationApp(defaults: defaults)
            for kind in signInOrder { app.add(kind) }
            XCTAssertEqual(app.families, ["codex", "claude"])
        }
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
        XCTAssertEqual(app.hidden(claude), ["extra", "sonnet"])
        XCTAssertEqual(app.order(claude).prefix(3), ["session", "weekly", "sonnet"])
        XCTAssertEqual(defaults.data(forKey: "openusage.layout.v2"), saved, "a second run writes nothing")

        XCTAssertTrue(app.layout.reorderMetric(dragged: "\(claude.cardID).sonnet", target: "\(claude.cardID).session", in: claude.cardID))
        XCTAssertTrue(app.layout.setMetric("\(claude.cardID).sonnet", shown: true))
        app.relaunch()
        XCTAssertEqual(app.order(claude).prefix(3), ["sonnet", "session", "weekly"])
        XCTAssertEqual(app.hidden(claude), ["extra"])
    }

    /// Shaped like a real 0.7.16 layout: a second Claude account's `@` id beside bare ids, a star on a
    /// metric it did not place, stars on rows that are gone, and a provider with no account today.
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

    func hidden(_ account: Account) -> [String] {
        layout.registry.descriptors(for: account.cardID).filter { !layout.isMetricShown($0.id) }.map(\.key).sorted()
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
