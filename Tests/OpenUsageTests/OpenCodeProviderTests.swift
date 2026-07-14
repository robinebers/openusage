import XCTest
@testable import OpenUsage

/// End-to-end provider behavior: detection via any OpenCode auth or local usage, and a refresh that
/// yields Go-only meters plus all-provider spend tiles and trend.
@MainActor
final class OpenCodeProviderTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private func row(
        _ iso: String,
        _ cost: String,
        _ tokens: Int,
        _ model: String,
        _ provider: String,
        input: Int? = nil,
        cacheRead: Int = 0,
        output: Int = 0,
        reasoning: Int = 0
    ) -> String {
        "[\(epochMs(iso)),\(cost),\(tokens),\"\(model)\",\"\(provider)\",\(input ?? tokens),\(cacheRead),0,\(output),\(reasoning),\"\(provider)-\(model)-\(epochMs(iso))\",1]"
    }
    private let authJSON = #"{"opencode-go":{"type":"api","key":"sk-test"}}"#
    private let openAIAuthJSON = #"{"openai":{"type":"oauth","access":"secret","refresh":"secret"}}"#

    private var testPricing: ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "gpt-test": ModelRates(
                    inputPerMillion: 2,
                    outputPerMillion: 10,
                    cacheWritePerMillion: 2,
                    cacheReadPerMillion: 0.2
                )
            ]),
            secondary: PricingCatalog()
        )
    }

    private func authStore(files: TextFileAccessing) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    func testHasLocalCredentialsViaGoAuthKey() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsViaExternalAuth() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": openAIAuthJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsViaLocalUsage() async {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsFalseWhenAbsent() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": "[]"]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertFalse(has)
    }

    func testRefreshProducesMetersTilesAndTrend() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + [
            row("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),
            row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode")
        ].joined(separator: ",") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now },
            pricing: { .empty }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testRefreshNotLoggedInWhenNoKeyAndNoDatabase() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            now: { now },
            pricing: { .empty }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshShowsZeroCapMetersWithGoKeyButNoDatabase() async {
        // Freshly logged into Go, before the first local message: the key alone establishes the plan,
        // so the published caps show at $0 instead of a bare "No usage data".
        let now = d("2026-07-12T12:00:00.000Z")
        let pricingCalls = PricingCallCounter()
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            now: { now },
            pricing: {
                await pricingCalls.increment()
                return .empty
            }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Go")
        guard case .progress(_, let used, let limit, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(used, 0)
        XCTAssertEqual(limit, OpenCodeUsageMapper.sessionCap)
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
        let pricingCallCount = await pricingCalls.value
        XCTAssertEqual(pricingCallCount, 0, "database discovery must happen before shared pricing is loaded")
    }

    func testRefreshExternalAuthWithoutDatabaseShowsNoDataNotLoginError() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let pricing = testPricing
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": openAIAuthJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            now: { now },
            pricing: { pricing }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.line(label: "Status"), .noUsageData)
    }

    func testRefreshErrorsWhenAllDatabasesUnreadable() async {
        // A valid Go key with a locked/corrupt database must surface a read error, not $0 meters.
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testRefreshSurfacesInvalidHostedCostAsSoftWarning() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + row("2026-07-12T10:00:00.000Z", "null", 100, "glm", "opencode-go") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now },
            pricing: { .empty }
        )

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testRefreshSurfacesUnreadableAuthFileInsteadOfNotLoggedIn() async {
        // auth.json exists but can't be read, and there's no database: broken storage, not logout.
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
    }

    func testHasLocalCredentialsTrueWhenAuthFileUnreadable() async {
        // An unreadable auth.json is itself an OpenCode footprint — enable the provider so refresh()
        // can show the actionable error rather than staying invisible.
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testSpendTilesMarkOpenCodeAPIRateValuesEstimated() async {
        // OpenCode derives per-message cost from model metadata, so it is an API-rate estimate rather
        // than a provider bill — including for Go/Zen rows where the database already has a value.
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now },
            pricing: { .empty }
        )
        let snapshot = await provider.refresh()
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        XCTAssertTrue(values.contains(where: \.estimated))
    }

    func testExternalOAuthUsageIsEstimatedWithoutGoMeters() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let pricing = testPricing
        let db = "[" + row(
            "2026-07-12T10:00:00.000Z", "0", 150, "gpt-test", "openai",
            input: 100, cacheRead: 20, output: 20, reasoning: 10
        ) + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": openAIAuthJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now },
            pricing: { pricing }
        )

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        guard case .values(_, let values, _, _, _, let breakdown)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        XCTAssertTrue(values.contains(where: \.estimated))
        XCTAssertEqual(breakdown?.models.first?.model, "openai/gpt-test")
    }

    func testUnknownExternalModelIsExcludedFromDisplayedTotals() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + [
            row("2026-07-12T10:00:00.000Z", "1", 500, "known", "opencode"),
            row("2026-07-12T09:00:00.000Z", "0", 321, "private", "openai")
        ].joined(separator: ",") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": openAIAuthJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now },
            pricing: { .empty }
        )

        let snapshot = await provider.refresh()
        guard case .values(_, let values, _, _, let unknownModels, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        XCTAssertEqual(values.first(where: { $0.kind == .dollars })?.number, 1)
        XCTAssertEqual(values.first(where: { $0.kind == .count })?.number, 500)
        XCTAssertEqual(unknownModels, ["openai/private"])
    }

    func testAllUnpricedUsageSurfacesModelInProviderWarning() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + row("2026-07-12T10:00:00.000Z", "0", 321, "private", "openai") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": openAIAuthJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now },
            pricing: { .empty }
        )

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.line(label: "Status"), .noUsageData)
        XCTAssertEqual(snapshot.warning, "OpenCode couldn't price usage for: openai/private.")
    }

    func testStaleGoHistoryDoesNotShowGoPlanOrMeters() async {
        // Zen-only recent usage + an old opencode-go anchor + no Go key: no "Go" badge, no cap meters,
        // but the Zen spend still shows in the tiles.
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db], anchor: "1700000000000"),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }
}

private actor PricingCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var anchor: String?
    var failing: Set<String>
    init(data: [String: String] = [:], anchor: String? = nil, failing: Set<String> = []) {
        self.data = data
        self.anchor = anchor
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") { return data[path] }
        if sql.contains("MIN(time_created)") { return anchor }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}
