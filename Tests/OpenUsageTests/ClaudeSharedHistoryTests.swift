import XCTest
@testable import OpenUsage

/// Claude's local history when several accounts are signed in. Claude Code writes no account id into
/// a session log, so per-account attribution discards nearly everything; the group shares one
/// combined history instead, the same way Codex does.
final class ClaudeSharedHistoryTests: XCTestCase {
    private typealias Entry = ClaudeLogUsageScanner.Entry

    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "claude-test-model": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20,
                cacheWritePerMillion: 12.5, cacheReadPerMillion: 1,
                fastMultiplier: 2
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    // MARK: - The sessions that used to be thrown away

    func testSharedScanCountsSessionsNoAccountClaims() async throws {
        // A log with no ownership header is what Claude Code actually writes. With several accounts
        // signed in this used to be dropped, which zeroed the spend tiles for every card.
        let now = Date()
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 100, output: 50, costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = await ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<Entry>(),
            accountUUID: "user-a", organizationUUID: "org-a",
            allowsUnattributedSessions: false, sharesLocalHistory: true
        ).scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(scan).series.daily.first?.totalTokens, 150)
    }

    func testPerAccountScanStillDropsThem() async throws {
        // The unshared path is unchanged: one account's card never claims another's usage.
        let now = Date()
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 100, output: 50, costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = await ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<Entry>(),
            accountUUID: "user-a", organizationUUID: "org-a",
            allowsUnattributedSessions: false, sharesLocalHistory: false
        ).scan(now: now, pricing: pricing)

        XCTAssertEqual(scan?.series.daily.first?.totalTokens ?? 0, 0)
    }

    func testSharedScanKeepsWorkingForADefaultLoginWithNoOrganization() async throws {
        // This combination used to bail out before reading a single file.
        let now = Date()
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 100, output: 50, costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = await ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<Entry>(),
            accountUUID: "user-a", organizationUUID: nil,
            allowsUnattributedSessions: false, sharesLocalHistory: true
        ).scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(scan).series.daily.first?.totalTokens, 150)
    }

    func testEverySharedScannerSeesEveryCoworkAccount() async throws {
        // Cowork discovery used to be narrowed to the card's own account before the shared bypass
        // ran, so each card reported a different partial total. Every card must see all of it.
        let now = Date()
        let timestamp = OpenUsageISO8601.string(from: now)
        let home = try ClaudeLogFixture.makeUserHome(
            claudeFiles: [
                "workspace/terminal.jsonl": ClaudeLogFixture.usageLine(
                    timestamp: timestamp, input: 40, output: 10, costUSD: 0.1,
                    messageID: "terminal", requestID: "terminal"
                )
            ],
            coworkSessions: [
                "user-a/org-a/local_a": [
                    "workspace/a.jsonl": ClaudeLogFixture.usageLine(
                        timestamp: timestamp, input: 80, output: 20, costUSD: 0.2,
                        messageID: "cowork-a", requestID: "cowork-a"
                    )
                ],
                "user-b/org-b/local_b": [
                    "workspace/b.jsonl": ClaudeLogFixture.usageLine(
                        timestamp: timestamp, input: 150, output: 50, costUSD: 0.4,
                        messageID: "cowork-b", requestID: "cowork-b"
                    )
                ]
            ]
        )
        defer { try? FileManager.default.removeItem(at: home) }

        for (account, organization) in [("user-a", "org-a"), ("user-b", "org-b")] {
            let scan = await ClaudeLogUsageScanner(
                environment: FakeEnvironment([:]), homeDirectory: { home },
                incrementalScanner: IncrementalJSONLScanner<Entry>(),
                accountUUID: account, organizationUUID: organization,
                allowsUnattributedSessions: false, sharesLocalHistory: true
            ).scan(now: now, pricing: pricing)

            XCTAssertEqual(try XCTUnwrap(scan).series.daily.first?.totalTokens, 350, account)
        }
    }

    @MainActor
    func testSharedCardsReadThePiFamilySliceWhateverTheirID() {
        // pi attributes Anthropic usage to "claude" and filters by exact card ID. An account card
        // asking under its own ID got nothing, and as the freshest source dropped pi from the group.
        let bare = ClaudeProvider(provider: ClaudeProvider.makeProvider(id: "claude"), sharesLocalHistory: true)
        let account = ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: "claude@1234abcd"), sharesLocalHistory: true
        )

        XCTAssertEqual(bare.piCardID, "claude")
        XCTAssertEqual(account.piCardID, "claude")
        XCTAssertEqual(PiUsageScanner.parseLine(Data(
            #"{"type":"message","id":"m1","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-4-8","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"cacheWrite1h":0,"totalTokens":150}}}"#.utf8
        ))?.cardID, "claude")
    }

    @MainActor
    func testAnUnsharedCardKeepsReadingItsOwnSlice() {
        let single = ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: "claude@1234abcd"), sharesLocalHistory: false
        )

        XCTAssertEqual(single.piCardID, "claude@1234abcd")
    }

    // MARK: - What the provider declares

    @MainActor
    func testSharedProviderMarksOnlyItsHistoryRows() throws {
        let descriptors = ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: "claude@a"), sharesLocalHistory: true
        ).widgetDescriptors

        let trend = try XCTUnwrap(descriptors.first { $0.sample.isChart })
        XCTAssertEqual(trend.historyResource?.sharedGroup, "claude")
        XCTAssertTrue(descriptors.filter { $0.isSpendTile }.allSatisfy(\.sample.isSharedHistory))
        // A quota row is this account's own and is never badged shared.
        XCTAssertTrue(descriptors.filter { !$0.isSpendTile && !$0.sample.isChart }
            .allSatisfy { !$0.sample.isSharedHistory })
    }

    @MainActor
    func testUnsharedProviderDeclaresNoGroup() throws {
        let descriptors = ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: "claude"), sharesLocalHistory: false
        ).widgetDescriptors

        let trend = try XCTUnwrap(descriptors.first { $0.sample.isChart })
        XCTAssertNil(trend.historyResource?.sharedGroup)
        XCTAssertTrue(descriptors.allSatisfy { !$0.sample.isSharedHistory })
    }

    @MainActor
    func testSharedHistoryIsNeverServedFromTheAccountCache() {
        // Shared history belongs to the group, so a card must not restore it as its own.
        XCTAssertFalse(ClaudeProvider(sharesLocalHistory: true).allowsCachedLocalHistory)
        XCTAssertTrue(ClaudeProvider(sharesLocalHistory: false).allowsCachedLocalHistory)
    }

    // MARK: - When the app turns it on

    @MainActor
    func testSeveralAccountsShareHistoryAndASingleAccountDoesNot() throws {
        let many = ProviderCatalog.make(defaults: defaults(), claudeCards: [
            card(id: "claude@a", organization: "org-a"),
            card(id: "claude@b", organization: "org-b")
        ]).compactMap { $0 as? ClaudeProvider }
        XCTAssertEqual(many.count, 2)
        XCTAssertTrue(many.allSatisfy(\.sharesLocalHistory))

        let one = ProviderCatalog.make(defaults: defaults(), claudeCards: [
            card(id: "claude@a", organization: "org-a")
        ]).compactMap { $0 as? ClaudeProvider }
        XCTAssertEqual(one.count, 1)
        XCTAssertFalse(one[0].sharesLocalHistory)
    }

    // MARK: - Helpers

    @MainActor
    private func defaults() -> UserDefaults {
        let name = "ClaudeSharedHistory.\(UUID().uuidString)"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }

    private func card(id: String, organization: String) -> ClaudeAccountCard {
        ClaudeAccountCard(
            id: id, identityKey: "user-\(id)|\(organization)", organizationID: organization,
            displayName: "Claude: \(id)", usesDesktopCredentials: false,
            allowsUnattributedPiUsage: false
        )
    }
}
