import XCTest
@testable import OpenUsage

@MainActor
final class LayoutMigrationTests: XCTestCase {
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
