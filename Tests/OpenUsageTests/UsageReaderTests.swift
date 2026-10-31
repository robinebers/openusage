import XCTest
@testable import OpenUsage

@MainActor
final class UsageReaderTests: XCTestCase {
    private func cache(_ snapshot: ProviderSnapshot, in defaults: UserDefaults) {
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        cache.save(cache.load().merging([snapshot.providerID: snapshot]) { $1 })
    }

    private func weekly(_ account: Account, used: Double, refreshedAt: Date = Date()) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: account.cardID,
            displayName: account.kind.displayName,
            lines: [.progress(label: "Weekly", used: used, limit: 100, format: .percent)],
            refreshedAt: refreshedAt
        )
    }

    private func providers(in result: UsageReadResult) throws -> [String: [String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        return try XCTUnwrap(root["providers"] as? [String: [String: Any]])
    }

    func testPrintsEveryCachedAccountFromTheAppDomain() throws {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let codex = store.add(kind: .codex, label: "Work", credential: .apiKey("k"))
        let claude = store.add(kind: .claude, label: "Claude", credential: .apiKey("k"))
        let pending = store.add(kind: .codex, label: "Home", credential: .apiKey("k"))
        cache(weekly(codex, used: 20), in: defaults)
        cache(weekly(claude, used: 30), in: defaults)

        let result = try UsageReader.read(defaults)
        let providers = try providers(in: result)

        XCTAssertTrue(result.hasSnapshots)
        XCTAssertEqual(Set(providers.keys), [codex.cardID, claude.cardID])
        XCTAssertNil(providers[pending.cardID])
        let resources = try XCTUnwrap(providers[codex.cardID]?["resources"] as? [String: Any])
        XCTAssertEqual((resources["weekly"] as? [String: Any])?["used"] as? Double, 20)
        XCTAssertEqual(providers[codex.cardID]?["displayName"] as? String, "ChatGPT · Work")
    }

    func testProviderKindNamesEveryAccountOfThatKindAndCardIDNamesOne() throws {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let first = store.add(kind: .codex, label: "Work", credential: .apiKey("k"))
        let second = store.add(kind: .codex, label: "Home", credential: .apiKey("k"))
        let claude = store.add(kind: .claude, label: "Claude", credential: .apiKey("k"))
        for account in [first, second, claude] {
            cache(weekly(account, used: 10), in: defaults)
        }

        XCTAssertEqual(Set(try providers(in: UsageReader.read(defaults, providerID: "codex")).keys), [first.cardID, second.cardID])
        XCTAssertEqual(Set(try providers(in: UsageReader.read(defaults, providerID: "Codex")).keys), [first.cardID, second.cardID])
        XCTAssertEqual(Set(try providers(in: UsageReader.read(defaults, providerID: second.cardID)).keys), [second.cardID])
        XCTAssertEqual(Set(try providers(in: UsageReader.read(defaults, providerID: "claude")).keys), [claude.cardID])
    }

    func testAnAccountIsStaleOnlyOnceTheAppShowsItsValuesAsOld() throws {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let recent = store.add(kind: .claude, label: "Recent", credential: .apiKey("k"))
        let old = store.add(kind: .claude, label: "Old", credential: .apiKey("k"))
        let now = Date()
        cache(weekly(recent, used: 10, refreshedAt: now.addingTimeInterval(-6 * 60)), in: defaults)
        cache(weekly(old, used: 10, refreshedAt: now.addingTimeInterval(-11 * 60)), in: defaults)

        let providers = try providers(in: UsageReader.read(defaults))

        XCTAssertEqual(providers[recent.cardID]?["stale"] as? Bool, false, "refreshed 6 minutes ago")
        XCTAssertEqual(providers[old.cardID]?["stale"] as? Bool, true, "refreshed 11 minutes ago")
        let app = WidgetDataStore.forTesting([], defaults: defaults, now: { now })
        app.snapshots = ProviderSnapshotCache(userDefaults: defaults).load()
        XCTAssertNil(app.stalenessHint(for: recent.cardID))
        XCTAssertNotNil(app.stalenessHint(for: old.cardID))
    }

    func testUnknownProviderThrowsEvenWhenNothingIsCached() {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        store.add(kind: .codex, label: "Work", credential: .apiKey("k"))

        XCTAssertThrowsError(try UsageReader.read(defaults, providerID: "cursor")) { error in
            guard case UsageReaderError.unknownProvider(let token) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(token, "cursor")
        }
        XCTAssertThrowsError(try UsageReader.read(defaults, providerID: "codex@00000000"))
    }

    func testAnEntryThisBuildCannotReadLeavesTheOtherAccountsReadable() throws {
        let defaults = isolatedDefaults()
        defaults.set(StoredAccountList.data, forKey: AccountStore.storageKey)
        cache(weekly(StoredAccountList.claude, used: 20), in: defaults)

        let result = try UsageReader.read(defaults)

        XCTAssertEqual(Set(try providers(in: result).keys), [StoredAccountList.claude.cardID])
    }

    func testNothingFetchedYetPrintsTheEmptyEnvelope() throws {
        let defaults = isolatedDefaults()
        let empty = try UsageReader.read(defaults)
        XCTAssertFalse(empty.hasSnapshots)
        XCTAssertTrue(try providers(in: empty).isEmpty)

        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        store.add(kind: .codex, label: "Work", credential: .apiKey("k"))
        let unfetched = try UsageReader.read(defaults, providerID: "codex")
        XCTAssertFalse(unfetched.hasSnapshots)
        XCTAssertTrue(try providers(in: unfetched).isEmpty)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: unfetched.data) as? [String: Any])
        XCTAssertEqual(root["schema"] as? String, "openusage.limits.v2")
    }
}
