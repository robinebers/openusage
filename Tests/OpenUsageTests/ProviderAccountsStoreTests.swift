import XCTest
@testable import OpenUsage

@MainActor
final class ProviderAccountsStoreTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func defaultHomeObservation(
        family: String,
        identityKey: String,
        label: String? = nil,
        anchor: String = "/Users/dev/.claude"
    ) -> ProviderAccountsStore.AccountObservation {
        ProviderAccountsStore.AccountObservation(
            family: family,
            identityKey: identityKey,
            label: label,
            sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
        )
    }

    func testFirstAccountOfAFamilyGetsTheBareID() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com"),
        ])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "claude", "the migration-killing rule: the first account IS the existing card")
        XCTAssertEqual(records[0].identityKey, "acct-a")
        XCTAssertEqual(records[0].label, "a@example.com")
        XCTAssertTrue(records[0].sources.contains(where: \.holdsDefaultSource))
    }

    func testSwappedDefaultMintsAHashIDAndTakesTheBadge() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])

        let records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-b")])

        XCTAssertEqual(records.count, 2, "the swapped-out account's record survives")
        let old = records.first { $0.identityKey == "acct-a" }
        let new = records.first { $0.identityKey == "acct-b" }
        XCTAssertEqual(old?.id, "claude", "the original keeps its minted id")
        XCTAssertEqual(new?.id, ProviderAccountID.make(family: "claude", identityKey: "acct-b"))
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.identityKey, "acct-b")
        XCTAssertEqual(old?.sources.contains(where: \.holdsDefaultSource), false, "the badge is exclusive per family")
    }

    func testUnobservedFamilyIsLeftUntouched() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "acct-c")])

        // A launch that could not observe codex (logged out, unreadable identity) reports nothing.
        let records = store.reconcile(with: [])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.identityKey, "acct-c")
    }

    func testReconcileUpdatesLabelButKeepsItWhenObservationHasNone() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com")])

        var records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])
        XCTAssertEqual(records[0].label, "a@example.com", "a label-less observation must not erase the known label")

        records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@new.example.com"),
        ])
        XCTAssertEqual(records[0].label, "a@new.example.com")
    }

    func testTombstonedRecordIsNeverResurrected() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "old")])
        // Simulate a future "Remove Account…" by tombstoning the persisted record directly.
        var records = store.records
        records[0].removedTombstone = true
        defaults.set(try! JSONEncoder().encode(records), forKey: ProviderAccountsStore.storageKey)

        let reloaded = ProviderAccountsStore(defaults: defaults)
        let after = reloaded.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "new"),
        ])

        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].label, "old", "a tombstoned account ignores rescan observations")
        XCTAssertNil(reloaded.defaultBadgeHolder(family: "claude"), "a tombstoned record never answers the badge")
    }

    func testRecordsPersistAcrossInstances() {
        let defaults = makeScratchDefaults()
        ProviderAccountsStore(defaults: defaults).reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com"),
            defaultHomeObservation(family: "codex", identityKey: "acct-c", anchor: "/Users/dev/.codex"),
        ])

        let reloaded = ProviderAccountsStore(defaults: defaults)

        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.defaultBadgeHolder(family: "claude")?.label, "a@example.com")
        XCTAssertEqual(reloaded.defaultBadgeHolder(family: "codex")?.sources.first?.anchor, "/Users/dev/.codex")
    }

    func testUndecodableRegistryStartsFresh() {
        let defaults = makeScratchDefaults()
        defaults.set(Data("not json".utf8), forKey: ProviderAccountsStore.storageKey)

        XCTAssertTrue(ProviderAccountsStore(defaults: defaults).records.isEmpty)
    }

    func testRenamePersistsAndAClearedNameFallsBackToTheDerivedOne() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com")])

        store.rename(cardID: "claude", to: "  Work  ")
        XCTAssertEqual(store.records[0].customLabel, "Work", "renames are trimmed")
        XCTAssertEqual(store.records[0].resolvedDisplayName, "Work", "the resolver surfaces the rename")
        XCTAssertEqual(ProviderAccountsStore(defaults: defaults).records[0].customLabel, "Work", "renames persist")

        store.rename(cardID: "claude", to: "   ")
        XCTAssertNil(store.records[0].customLabel, "a blank rename clears back to the derived name")
        XCTAssertEqual(store.records[0].resolvedDisplayName, "Claude", "the bare card derives the stock family name")

        store.rename(cardID: "missing", to: "X")
        XCTAssertEqual(store.records.count, 1, "renaming an unknown card is a no-op")
    }

    func testReconcileNeverTouchesACustomLabel() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "old")])
        store.rename(cardID: "claude", to: "Work")

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "new"),
        ])

        XCTAssertEqual(records[0].label, "new")
        XCTAssertEqual(records[0].customLabel, "Work", "rescans update the label but never the rename")
    }

    func testFamilyHelperSplitsCardIDs() {
        XCTAssertEqual(ProviderAccountID.family(of: "claude"), "claude")
        XCTAssertEqual(ProviderAccountID.family(of: "claude@ab12cd34"), "claude")
        XCTAssertEqual(ProviderAccountID.family(of: "cursor"), "cursor")
    }
}
