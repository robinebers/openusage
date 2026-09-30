import XCTest
@testable import OpenUsage

/// Issue #1315: last-good usage lives in memory only, so a relaunch during a usage-API rate limit used to
/// replace the account-checked launch-cache paint with the bare rate-limited badge ("No data" rows).
@MainActor
final class ClaudeLaunchSnapshotTests: XCTestCase {
    private nonisolated static let account = "11111111-1111-4111-8111-111111111111"
    private nonisolated static let organization = "22222222-2222-4222-8222-222222222222"
    private nonisolated static let identity = "\(account)|\(organization)"
    private nonisolated static let now = OpenUsageISO8601.date(from: "2026-02-20T16:00:00.000Z")!
    private nonisolated static let future = OpenUsageISO8601.date(from: "2099-01-01T00:00:00.000Z")!
    private let path = "/tmp/claude/.credentials.json"

    func testRelaunchRateLimitKeepsVerifiedLaunchLimitsWithNoteAndWarning() async {
        let defaults = makeUserDefaults("relaunch")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Self.now })
        cache.store(launchSnapshot(), producedByIdentityKey: Self.identity)
        let fixture = makeFixture { request in
            request.url.path == "/api/oauth/profile" ? Self.profileResponse() : Self.rateLimited()
        }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [fixture.provider.provider], descriptors: []),
            providers: [fixture.provider],
            cache: cache,
            defaults: defaults,
            now: { Self.now },
            providerIdentityKeys: ["claude": Self.identity]
        )

        await store.refresh(providerID: "claude")

        let snapshot = store.snapshots["claude"]
        XCTAssertEqual(progressUsed(snapshot?.lines, "Session"), 40)
        XCTAssertEqual(progressUsed(snapshot?.lines, "Weekly"), 60)
        XCTAssertEqual(progressUsed(snapshot?.lines, "Fable"), 10)
        XCTAssertNotNil(snapshot?.lines.first { $0.label == "Rate Limit Resets" })
        XCTAssertNil(snapshot?.lines.first { $0.label == "Status" })
        XCTAssertNil(snapshot?.lines.first { $0.label == "Today" }, "cached spend tiles are recomputed, never replayed")
        XCTAssertEqual(snapshot?.lines.filter { $0.label == "Note" }.count, 1)
        XCTAssertEqual(snapshot?.warning?.hasPrefix("Updates blocked by Anthropic"), true)
        XCTAssertEqual(snapshot?.plan, "Max 20x")
    }

    func testRateLimitWithoutLaunchSnapshotServesBadge() async {
        let fixture = makeFixture { request in
            request.url.path == "/api/oauth/profile" ? Self.profileResponse() : Self.rateLimited()
        }

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Status")?.hasPrefix("Rate limited"), true)
        XCTAssertNil(progressUsed(snapshot.lines, "Session"))
        XCTAssertEqual(snapshot.warning?.hasPrefix("Updates blocked by Anthropic"), true)
    }

    func testLaunchSnapshotStampedByAnotherAccountIsNotAdopted() {
        let defaults = makeUserDefaults("other-account")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Self.now })
        cache.store(launchSnapshot(), producedByIdentityKey: "other-account|other-org")
        cache.store(launchSnapshot(providerID: "claude-unresolved"), producedByIdentityKey: Self.identity)
        let stamped = AdoptionRecordingRuntime(id: "claude")
        let unresolved = AdoptionRecordingRuntime(id: "claude-unresolved")

        _ = WidgetDataStore(
            registry: WidgetRegistry(providers: [stamped.provider, unresolved.provider], descriptors: []),
            providers: [stamped, unresolved],
            cache: cache,
            defaults: defaults,
            providerIdentityKeys: ["claude": Self.identity]
        )

        XCTAssertTrue(stamped.adopted.isEmpty)
        XCTAssertTrue(unresolved.adopted.isEmpty, "a card without a known identity can't vouch for its cache")
    }

    func testLoginFailingAccountCheckNeverConsumesLaunchSnapshot() async {
        let profileAccount = LaunchSnapshotLockedValue("someone-else")
        let fixture = makeFixture { request in
            if request.url.path == "/api/oauth/profile" {
                return Self.profileResponse(account: profileAccount.value)
            }
            return Self.rateLimited()
        }
        fixture.provider.adoptLaunchSnapshot(launchSnapshot())

        let rejected = await fixture.provider.refresh()
        XCTAssertNil(progressUsed(rejected.lines, "Session"))

        profileAccount.value = Self.account
        let verified = await fixture.provider.refresh()
        XCTAssertEqual(progressUsed(verified.lines, "Session"), 40)
        XCTAssertEqual(verified.warning?.hasPrefix("Updates blocked by Anthropic"), true)
    }

    func testCardWithoutVerifiableIdentityKeepsBadge() async {
        let fixture = makeFixture(expectedIdentityKey: nil) { _ in Self.rateLimited() }
        fixture.provider.adoptLaunchSnapshot(launchSnapshot())

        let snapshot = await fixture.provider.refresh()

        XCTAssertEqual(badge(snapshot.lines, "Status")?.hasPrefix("Rate limited"), true)
        XCTAssertNil(progressUsed(snapshot.lines, "Session"))
    }

    func testSuccessfulFetchDiscardsLaunchSnapshot() async {
        let usageCalls = LaunchSnapshotLockedValue(0)
        let fixture = makeFixture { request in
            if request.url.path == "/api/oauth/profile" { return Self.profileResponse() }
            usageCalls.value += 1
            return usageCalls.value == 1 ? Self.usage(percent: 25) : Self.rateLimited()
        }
        fixture.provider.adoptLaunchSnapshot(launchSnapshot())

        let live = await fixture.provider.refresh()
        XCTAssertEqual(progressUsed(live.lines, "Session"), 25)

        // A new token pair for the same account starts with no last-good usage; the discarded launch
        // snapshot must not come back for its first 429.
        fixture.files.files[path] = Self.credentials(access: "token-b", refresh: "refresh-b")
        let limited = await fixture.provider.refresh()
        XCTAssertNil(progressUsed(limited.lines, "Session"))
        XCTAssertEqual(badge(limited.lines, "Status")?.hasPrefix("Rate limited"), true)
    }

    func testLaunchWindowWhoseResetPassedIsDropped() async {
        let fixture = makeFixture { request in
            request.url.path == "/api/oauth/profile" ? Self.profileResponse() : Self.rateLimited()
        }
        let elapsed = Self.now.addingTimeInterval(-60)
        fixture.provider.adoptLaunchSnapshot(launchSnapshot(sessionResetsAt: elapsed))

        let snapshot = await fixture.provider.refresh()

        XCTAssertNil(progressUsed(snapshot.lines, "Session"))
        XCTAssertEqual(progressUsed(snapshot.lines, "Weekly"), 60)
        XCTAssertEqual(snapshot.warning?.hasPrefix("Updates blocked by Anthropic"), true)
    }

    func testLaunchResetGrantsPastTheirDeadlineAreDropped() async {
        let fixture = makeFixture { request in
            request.url.path == "/api/oauth/profile" ? Self.profileResponse() : Self.rateLimited()
        }
        let elapsed = Self.now.addingTimeInterval(-60)
        // Three grants: one elapsed, one still open, one with no known deadline.
        fixture.provider.adoptLaunchSnapshot(launchSnapshot(resetGrants: 3, resetExpiries: [elapsed, Self.future]))

        let snapshot = await fixture.provider.refresh()

        let row = resetsRow(snapshot.lines)
        XCTAssertEqual(row?.count, 2)
        XCTAssertEqual(row?.expiriesAt, [Self.future])
    }

    func testLaunchResetGrantsAllExpiredReadZeroAvailable() async {
        let fixture = makeFixture { request in
            request.url.path == "/api/oauth/profile" ? Self.profileResponse() : Self.rateLimited()
        }
        let elapsed = Self.now.addingTimeInterval(-60)
        fixture.provider.adoptLaunchSnapshot(launchSnapshot(resetGrants: 2, resetExpiries: [elapsed, elapsed]))

        let snapshot = await fixture.provider.refresh()

        let row = resetsRow(snapshot.lines)
        XCTAssertEqual(row?.count, 0)
        XCTAssertEqual(row?.expiriesAt, [])
        XCTAssertEqual(progressUsed(snapshot.lines, "Session"), 40)
    }

    // MARK: - Helpers

    private struct Fixture {
        let provider: ClaudeProvider
        let files: FakeFiles
    }

    private func makeFixture(
        expectedIdentityKey: String? = ClaudeLaunchSnapshotTests.identity,
        handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) -> Fixture {
        let files = FakeFiles([path: Self.credentials(access: "token-a", refresh: "refresh-a")])
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: files,
            keychain: FakeKeychain(),
            expectedIdentityKey: expectedIdentityKey,
            now: { Self.now }
        )
        let provider = ClaudeProvider(
            authStore: authStore,
            usageClient: ClaudeUsageClient(httpClient: RoutingHTTPClient(handler: handler)),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { Self.now },
            pricing: { TestPricing.bundled }
        )
        return Fixture(provider: provider, files: files)
    }

    private func launchSnapshot(
        providerID: String = "claude",
        sessionResetsAt: Date = future,
        resetGrants: Int = 1,
        resetExpiries: [Date] = []
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: providerID,
            displayName: "Claude",
            plan: "Max 5x",
            lines: [
                .progress(label: "Session", used: 40, limit: 100, format: .percent, resetsAt: sessionResetsAt, periodDurationMs: MetricPeriod.sessionMs),
                .progress(label: "Weekly", used: 60, limit: 100, format: .percent, resetsAt: Self.future, periodDurationMs: MetricPeriod.weekMs),
                .progress(label: "Fable", used: 10, limit: 100, format: .percent, resetsAt: Self.future),
                .values(
                    label: "Rate Limit Resets",
                    values: [MetricValue(number: Double(resetGrants), kind: .count, label: "available")],
                    expiriesAt: resetExpiries
                ),
                .values(label: "Today", values: [MetricValue(number: 3, kind: .dollars)]),
                ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: 600)
            ],
            refreshedAt: Self.now.addingTimeInterval(-1800)
        )
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "ClaudeLaunchSnapshotTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private nonisolated static func credentials(access: String, refresh: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refresh)","expiresAt":4102444800000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:profile"]}}"#
    }

    private nonisolated static func rateLimited() -> HTTPResponse {
        HTTPResponse(statusCode: 429, headers: ["retry-after": "600"], body: Data())
    }

    private nonisolated static func usage(percent: Int) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"five_hour":{"utilization":\#(percent),"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
        )
    }

    private nonisolated static func profileResponse(account: String = account) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(
                #"{"account":{"uuid":"\#(account)","has_claude_max":true},"organization":{"uuid":"\#(organization)","organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x","subscription_status":"active"}}"#
                    .utf8
            )
        )
    }

    private func progressUsed(_ lines: [MetricLine]?, _ label: String) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _) = lines?.first(where: { $0.label == label }) else {
            return nil
        }
        return used
    }

    private func resetsRow(_ lines: [MetricLine]) -> (count: Double?, expiriesAt: [Date])? {
        guard case .values(_, let values, _, let expiriesAt, _, _) = lines.first(where: { $0.label == "Rate Limit Resets" })
        else { return nil }
        return (values.first?.number, expiriesAt)
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> String? {
        guard case .badge(_, let text, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return text
    }
}

@MainActor
private final class AdoptionRecordingRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private(set) var adopted: [ProviderSnapshot] = []

    init(id: String) {
        provider = ClaudeProvider.makeProvider(id: id)
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [], refreshedAt: Date())
    }

    func adoptLaunchSnapshot(_ snapshot: ProviderSnapshot) {
        adopted.append(snapshot)
    }
}

private final class LaunchSnapshotLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
