import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeInstanceSourceRegressionTests: XCTestCase {
    private let teamKey = "uuid-me|org-team"
    private let maxKey = "uuid-me|org-max"

    func testSwapDiscoveryReadsRotatedLogsOldestToNewestWithoutUnsafeBackfill() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSwapFixture(home: home, sequence: 2)
        try write(home, ".claude-swap-backup/claude-swap.log.3", """
        2026-07-16 10:00:00,000 - INFO - Starting up
        2026-07-16 11:00:00,000 - INFO - Switched from account 1 to 2
        """)
        try write(home, ".claude-swap-backup/claude-swap.log.2",
                  "2026-07-16 12:00:00,000 - INFO - Switched from account 2 to 1\n")
        try write(home, ".claude-swap-backup/claude-swap.log.1",
                  "2026-07-16 13:00:00,000 - INFO - Switched from account 1 to 2\n")
        // A fresh current file with no switch must not hide the events retained in its archives.
        try write(home, ".claude-swap-backup/claude-swap.log",
                  "2026-07-16 14:00:00,000 - INFO - Heartbeat\n")

        let result = discovery(home: home).run()
        let timeline = try XCTUnwrap(result.claudeSwapTimeline)

        XCTAssertNil(timeline.identityKey(at: localDate("2026-07-16 09:00:00")),
                     "with .3 retained, older archives may be gone and prehistory must stay unattributed")
        XCTAssertEqual(timeline.identityKey(at: localDate("2026-07-16 10:30:00")), teamKey)
        XCTAssertEqual(timeline.identityKey(at: localDate("2026-07-16 11:30:00")), maxKey)
        XCTAssertEqual(timeline.identityKey(at: localDate("2026-07-16 12:30:00")), teamKey)
        XCTAssertEqual(timeline.identityKey(at: localDate("2026-07-16 13:30:00")), maxKey)
        XCTAssertTrue(result.notes.contains { $0.contains("4 retained log file(s)") })
    }

    func testSwapActiveSlotUsesLiveIdentityWhenSequenceDrifts() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSwapFixture(home: home, sequence: 1)

        let result = discovery(home: home).run()

        XCTAssertEqual(result.instances.count, 1)
        XCTAssertEqual(result.instances[0].identityKey, teamKey)
        XCTAssertEqual(result.instances[0].swapAccountName, "account-1-me@x.com")
        XCTAssertTrue(result.notes.contains {
            $0.contains("sequence=1 disagrees") && $0.contains("using slot 2")
        })
    }

    func testSwapVaultPrefersValidEncAndFallsBackWhenEncIsInvalid() throws {
        let account = "account-1-me@x.com"
        let root = "/Users/x/.claude-swap-backup"
        let encPath = "\(root)/credentials/.creds-1-me@x.com.enc"
        let keychain = AccountAwareKeychain()
        keychain.accountValues["claude-swap|\(account)"] = credentialsJSON(access: "keychain-token")

        let encoded = Data(credentialsJSON(access: "enc-token").utf8).base64EncodedString()
        let authoritative = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([encPath: encoded]),
            keychain: keychain,
            scope: .swapSlot(account: account, backupRoot: root, organization: nil)
        )
        XCTAssertEqual(authoritative.loadCredentialSet().candidates.first?.oauth.accessToken, "enc-token")

        let invalid = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([encPath: Data(#"{"notCredentials":true}"#.utf8).base64EncodedString()]),
            keychain: keychain,
            scope: .swapSlot(account: account, backupRoot: root, organization: nil)
        )
        XCTAssertEqual(invalid.loadCredentialSet().candidates.first?.oauth.accessToken, "keychain-token")
    }

    func testDuplicateConfigHomesRetainEveryUsageRoot() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude.json", identityJSON(uuid: "uuid-default", org: "org-default"))
        for name in [".claude-team-a", ".claude-team-b"] {
            try write(home, "\(name)/.claude.json", identityJSON(uuid: "uuid-me", org: "org-team"))
            try write(home, "\(name)/.credentials.json", credentialsJSON(access: "token-\(name)"))
        }

        let result = discovery(home: home).run()

        XCTAssertEqual(result.instances.filter { $0.identityKey == teamKey }.count, 1)
        XCTAssertEqual(
            result.coworkRootsByIdentityKey[teamKey]?.map(\.lastPathComponent),
            [".claude-team-b"]
        )
    }

    func testConfigAndSwapSourcesMergeAccountSpecificAndSharedUsage() async throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSwapFixture(home: home, sequence: 2)

        let configRoot = home.appendingPathComponent(".claude-team")
        try write(home, ".claude-team/.claude.json", identityJSON(uuid: "uuid-me", org: "org-team"))
        try write(home, ".claude-team/.credentials.json", credentialsJSON(access: "config-token"))

        let sharedTimestamp = OpenUsageISO8601.string(from: localDate("2026-07-16 10:30:00"))
        let configTimestamp = OpenUsageISO8601.string(from: localDate("2026-07-16 12:30:00"))
        try write(home, ".claude/projects/shared.jsonl", ClaudeLogFixture.usageLine(
            timestamp: sharedTimestamp, costUSD: 1, messageID: "shared", requestID: "shared"
        ))
        try write(home, ".claude-team/projects/config.jsonl", ClaudeLogFixture.usageLine(
            timestamp: configTimestamp, costUSD: 2, messageID: "config", requestID: "config"
        ))
        try write(home, ".claude-swap-backup/claude-swap.log", """
        2026-07-16 09:00:00,000 - INFO - Starting up
        2026-07-16 11:00:00,000 - INFO - Switched from account 1 to 2
        """)

        let discovered = discovery(home: home).run()
        let finding = try XCTUnwrap(discovered.instances.first { $0.identityKey == teamKey })
        XCTAssertEqual(finding.kind, .claudeSwapSlot, "cswap owns the parked credential lifecycle")
        XCTAssertEqual(
            discovered.coworkRootsByIdentityKey[teamKey]?.map { $0.resolvingSymlinksInPath().standardizedFileURL.path },
            [configRoot.resolvingSymlinksInPath().standardizedFileURL.path]
        )

        let id = ProviderInstanceID.make(baseProviderID: "claude", identityKey: teamKey)
        let record = ProviderInstanceRecord(
            id: id,
            baseProviderID: "claude",
            ordinal: 2,
            kind: finding.kind,
            anchorPath: finding.anchorPath,
            keychainLiteral: finding.keychainLiteral,
            desktopOrganization: finding.desktopOrganization,
            swapAccountName: finding.swapAccountName,
            identityKey: finding.identityKey,
            identityLabel: finding.identityLabel
        )
        let context = ProviderInstanceContext(
            records: [record],
            coworkRootsByInstanceID: [id: discovered.coworkRootsByIdentityKey[teamKey] ?? []],
            claudeSwapTimeline: discovered.claudeSwapTimeline,
            claudeSharedHomeRoots: discovered.claudeSharedHomeRoots,
            defaultClaudeIdentityKey: maxKey
        )
        let runtime = try XCTUnwrap(
            ProviderCatalog.make(instanceContext: context)
                .first { $0.provider.id == id } as? ClaudeProvider
        )

        let now = localDate("2026-07-17 12:00:00")
        let sharedResult = await runtime.logUsageScanner.scan(now: now, pricing: TestPricing.bundled)
        let shared = try XCTUnwrap(sharedResult)
        XCTAssertEqual(shared.series.daily.reduce(0) { $0 + ($1.costUSD ?? 0) }, 1, accuracy: 0.000_001)
        XCTAssertEqual(runtime.extraLogUsageScanners.count, 1)
        let configResult = await runtime.extraLogUsageScanners[0].scan(now: now, pricing: TestPricing.bundled)
        let config = try XCTUnwrap(configResult)
        XCTAssertEqual(config.series.daily.reduce(0) { $0 + ($1.costUSD ?? 0) }, 2, accuracy: 0.000_001)
    }

    func testCatalogPinsOrDisablesDefaultDesktopFallbackWhenInstancesExist() throws {
        let org = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let record = ProviderInstanceRecord(
            id: "claude@team", baseProviderID: "claude", ordinal: 2,
            kind: .claudeDesktop, anchorPath: nil, keychainLiteral: nil,
            desktopOrganization: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            identityKey: "uuid-team|bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", identityLabel: nil
        )

        let pinned = ProviderInstanceContext(records: [record], defaultClaudeIdentityKey: "uuid-default|\(org)")
        let pinnedRuntime = try XCTUnwrap(ProviderCatalog.make(instanceContext: pinned).first as? ClaudeProvider)
        XCTAssertEqual(pinnedRuntime.authStore.standardDesktopOrganization, org)
        XCTAssertFalse(pinnedRuntime.authStore.allowsUnpinnedStandardDesktopFallback)

        let unpinnable = ProviderInstanceContext(records: [record], defaultClaudeIdentityKey: "uuid-default")
        let unpinnableRuntime = try XCTUnwrap(ProviderCatalog.make(instanceContext: unpinnable).first as? ClaudeProvider)
        XCTAssertNil(unpinnableRuntime.authStore.standardDesktopOrganization)
        XCTAssertFalse(unpinnableRuntime.authStore.allowsUnpinnedStandardDesktopFallback)
        XCTAssertEqual(unpinnableRuntime.authStore.loadCredentialSet().desktopStatus, .notChecked)
        XCTAssertEqual(
            unpinnableRuntime.authStore.loadCredentialSet(forceDesktopFallback: true).desktopStatus,
            .notFound,
            "an unsafe fallback reports no candidate so the provider preserves the original CLI auth error"
        )
    }

    func testCatalogWiresFoldedDefaultClaudeSourceAsAnAdditionalScanner() throws {
        let sibling = URL(fileURLWithPath: "/Users/x/.claude-copy")
        let context = ProviderInstanceContext(
            records: [],
            defaultClaudeAdditionalLogRoots: [sibling],
            defaultClaudeIdentityKey: "uuid-default|org-default"
        )

        let runtime = try XCTUnwrap(
            ProviderCatalog.make(instanceContext: context).first as? ClaudeProvider
        )

        XCTAssertEqual(runtime.extraLogUsageScanners.count, 1)
    }

    private func discovery(home: URL) -> ProviderInstanceDiscovery {
        ProviderInstanceDiscovery(
            environment: FakeEnvironment([:]),
            keychain: AccountAwareKeychain(),
            homeDirectory: { home }
        )
    }

    private func writeSwapFixture(home: URL, sequence: Int) throws {
        try write(home, ".claude.json", identityJSON(uuid: "uuid-me", org: "org-max"))
        try write(home, ".claude-swap-backup/configs/.claude-config-1-me@x.com.json",
                  identityJSON(uuid: "uuid-me", org: "org-team"))
        try write(home, ".claude-swap-backup/configs/.claude-config-2-me@x.com.json",
                  identityJSON(uuid: "uuid-me", org: "org-max"))
        try write(home, ".claude-swap-backup/sequence.json", #"{"activeAccountNumber": \#(sequence)}"#)
    }

    private func localDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)!
    }

    private func makeFixtureHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-claude-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ home: URL, _ relative: String, _ contents: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func identityJSON(uuid: String, org: String) -> String {
        #"{"oauthAccount":{"accountUuid":"\#(uuid)","emailAddress":"me@x.com","organizationUuid":"\#(org)","organizationName":"Org"}}"#
    }

    private func credentialsJSON(access: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"r","expiresAt":9999999999999,"subscriptionType":"max","scopes":["user:profile","user:inference"]}}"#
    }
}
