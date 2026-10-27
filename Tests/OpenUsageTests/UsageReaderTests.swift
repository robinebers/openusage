import XCTest
@testable import OpenUsage

@MainActor
final class UsageReaderTests: XCTestCase {
    private func cache(_ snapshot: ProviderSnapshot, in defaults: UserDefaults) {
        ProviderSnapshotCache(userDefaults: defaults).store(snapshot)
    }

    private func weekly(_ account: Account, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: account.cardID,
            displayName: account.kind.displayName,
            lines: [.progress(label: "Weekly", used: used, limit: 100, format: .percent)]
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

        let result = try UsageReader(userDefaults: defaults).read()
        let providers = try providers(in: result)

        XCTAssertTrue(result.hasSnapshots)
        XCTAssertEqual(Set(providers.keys), [codex.cardID, claude.cardID])
        XCTAssertNil(providers[pending.cardID])
        let resources = try XCTUnwrap(providers[codex.cardID]?["resources"] as? [String: Any])
        XCTAssertEqual((resources["weekly"] as? [String: Any])?["used"] as? Double, 20)
        XCTAssertEqual(providers[codex.cardID]?["displayName"] as? String, "Codex")
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
        let reader = UsageReader(userDefaults: defaults)

        XCTAssertEqual(Set(try providers(in: reader.read(providerID: "codex")).keys), [first.cardID, second.cardID])
        XCTAssertEqual(Set(try providers(in: reader.read(providerID: "Codex")).keys), [first.cardID, second.cardID])
        XCTAssertEqual(Set(try providers(in: reader.read(providerID: second.cardID)).keys), [second.cardID])
        XCTAssertEqual(Set(try providers(in: reader.read(providerID: "claude")).keys), [claude.cardID])
    }

    func testUnknownProviderThrowsEvenWhenNothingIsCached() {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        store.add(kind: .codex, label: "Work", credential: .apiKey("k"))

        XCTAssertThrowsError(try UsageReader(userDefaults: defaults).read(providerID: "cursor")) { error in
            guard case UsageReaderError.unknownProvider(let token) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(token, "cursor")
        }
        XCTAssertThrowsError(try UsageReader(userDefaults: defaults).read(providerID: "codex@00000000"))
    }

    func testNothingFetchedYetPrintsTheEmptyEnvelope() throws {
        let defaults = isolatedDefaults()
        let empty = try UsageReader(userDefaults: defaults).read()
        XCTAssertFalse(empty.hasSnapshots)
        XCTAssertTrue(try providers(in: empty).isEmpty)

        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        store.add(kind: .codex, label: "Work", credential: .apiKey("k"))
        let unfetched = try UsageReader(userDefaults: defaults).read(providerID: "codex")
        XCTAssertFalse(unfetched.hasSnapshots)
        XCTAssertTrue(try providers(in: unfetched).isEmpty)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: unfetched.data) as? [String: Any])
        XCTAssertEqual(root["schema"] as? String, "openusage.limits.v1")
    }
}
