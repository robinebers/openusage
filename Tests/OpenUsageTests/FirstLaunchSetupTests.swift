import Security
import XCTest
@testable import OpenUsage

/// The welcome screen: what it finds without asking, and how Connect turns providers on.
@MainActor
final class FirstLaunchSetupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainAccessGuard.forgetDenials()
    }

    func testWelcomeIsSkippedOnceAProviderChoiceIsSaved() {
        let defaults = makeScratchDefaults("FirstLaunchSetup")
        FirstLaunchSetup.markPending(defaults: defaults)
        XCTAssertTrue(FirstLaunchSetup.isPending(defaults: defaults))
        FirstLaunchSetup.clearPending(defaults: defaults)
        XCTAssertFalse(FirstLaunchSetup.isPending(defaults: defaults))

        // An unbundled `swift run` reports a fresh install on every launch.
        ProviderEnablementStore(defaults: defaults).seedEnabledProviders([])
        FirstLaunchSetup.markPending(defaults: defaults)
        XCTAssertFalse(FirstLaunchSetup.isPending(defaults: defaults))
    }

    func testDetectionPreselectsTheProvidersSignedInOnThisMac() async {
        let (setup, _) = makeSetup(cards: [
            StubRuntime("claude", hasCredentials: true),
            StubRuntime("codex", hasCredentials: false),
        ])

        await setup.detect()

        XCTAssertEqual(setup.selectedIDs, ["claude"])
        XCTAssertEqual(setup.visibleChoices.map(\.id), ["claude"])
        setup.showAll = true
        XCTAssertEqual(setup.visibleChoices.map(\.id), ["claude", "codex"])
    }

    func testDetectionAsksEveryDashboardCard() async {
        let (setup, _) = makeSetup(cards: [
            StubRuntime("codex", hasCredentials: false),
            StubRuntime("codex@ab12cd34", hasCredentials: true),
        ])

        await setup.detect()

        XCTAssertEqual(setup.selectedIDs, ["codex"], "a login only an account card sees, like a second Codex home, is on this Mac")
    }

    func testCodexKeychainLoginCountsBeforeOpenUsageMayReadIt() async {
        let codex = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/test/codex"]),
                files: FakeFiles(),
                keychain: UnreadableKeychain()
            ),
            usageClient: CodexUsageClient(http: FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data())))
        )

        let detected = await codex.hasLocalCredentials()

        XCTAssertTrue(detected)
    }

    func testConnectTurnsOnEveryCardOneRefreshAtATime() async {
        let log = RefreshLog()
        let (setup, enablement) = makeSetup(cards: ["claude", "claude@ab12cd34", "codex"].map { id in
            StubRuntime(id) { await log.record(id) }
        })
        await setup.detect()

        await setup.connectSelected()

        XCTAssertEqual(enablement.enabledIDs, ["claude", "claude@ab12cd34", "codex"])
        XCTAssertEqual(setup.choices.map(\.connection), [.connected, .connected])
        XCTAssertEqual(log.events, [
            "start claude", "end claude", "start claude@ab12cd34", "end claude@ab12cd34", "start codex", "end codex",
        ], "overlapping refreshes could put up two Keychain popups at once")
    }

    func testFailedCardGoesBackOffAndShowsWhy() async {
        let (setup, enablement) = makeSetup(cards: [
            StubRuntime("claude"),
            StubRuntime("claude@ab12cd34") { "Session expired. Sign in again." },
        ])
        await setup.detect()

        await setup.connectSelected()

        XCTAssertEqual(enablement.enabledIDs, ["claude"])
        XCTAssertEqual(setup.choices.map(\.connection), [.failed("Session expired. Sign in again.")])
        XCTAssertTrue(setup.hasFailures)
    }

    func testDenyWhileConnectingSaysAccessWasNotGranted() async {
        let keychain = SecurityKeychainAccessor(itemAccessor: DenyingItemAccessor())
        let (setup, enablement) = makeSetup(cards: [
            StubRuntime("codex") {
                (try? keychain.readGenericPassword(service: "Denied Welcome Login")) == nil ? "Not logged in." : nil
            },
        ])
        await setup.detect()

        await setup.connectSelected()

        XCTAssertEqual(setup.choices.map(\.connection), [.failed(FirstLaunchSetup.accessDeniedMessage)])
        XCTAssertEqual(enablement.enabledIDs, [])
    }

    func testPopupLeftOpenPastTheRefreshDeadlineHoldsTheNextProvider() async throws {
        let popup = OpenPopupItemAccessor()
        let keychain = SecurityKeychainAccessor(itemAccessor: popup)
        let log = RefreshLog()
        let (setup, _) = makeSetup(cards: [
            StubRuntime("claude") {
                DispatchQueue.global().async { _ = try? keychain.readGenericPassword(service: "Open Welcome Popup") }
                await popup.waitUntilShown()
                return "Timed out."
            },
            StubRuntime("codex") { await log.record("codex") },
        ])
        await setup.detect()

        let connecting = Task { await setup.connectSelected() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(log.events, [], "a second popup must not open while the first is still up")
        popup.answer()
        await connecting.value

        XCTAssertEqual(log.events, ["start codex", "end codex"])
    }

    // MARK: - Helpers

    private func makeSetup(cards: [StubRuntime]) -> (FirstLaunchSetup, ProviderEnablementStore) {
        let enablement = ProviderEnablementStore(defaults: makeScratchDefaults("FirstLaunchSetup"))
        enablement.seedEnabledProviders([])
        let defaults = makeScratchDefaults("FirstLaunchSetup.Cache")
        let dataStore = WidgetDataStore(
            registry: WidgetRegistry(providers: cards.map(\.provider), descriptors: []),
            providers: cards,
            cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) }
        )
        let setup = FirstLaunchSetup(
            providers: cards.map(\.provider).filter { ProviderAccountID.family(of: $0.id) == $0.id },
            cards: cards,
            enablement: enablement,
            dataStore: dataStore
        )
        return (setup, enablement)
    }
}

@MainActor
private final class StubRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool
    private let fetch: @MainActor () async -> String?

    init(_ id: String, hasCredentials: Bool = true, fetch: @escaping @MainActor () async -> String? = { nil }) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
        self.fetch = fetch
    }

    func hasLocalCredentials() async -> Bool { hasCredentials }

    func refresh() async -> ProviderSnapshot {
        if let failure = await fetch() { return .error(provider: provider, message: failure) }
        return ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }
}

@MainActor
private final class RefreshLog {
    private(set) var events: [String] = []

    func record(_ id: String) async -> String? {
        events.append("start \(id)")
        try? await Task.sleep(for: .milliseconds(10))
        events.append("end \(id)")
        return nil
    }
}

private struct UnreadableKeychain: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? {
        throw KeychainError.readFailed("not allowed")
    }

    func writeGenericPassword(service: String, value: String) throws {}

    func genericPasswordExists(service: String) -> Bool? { true }
}

private struct DenyingItemAccessor: SecurityItemAccessing {
    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        (errSecAuthFailed, nil)
    }

    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) {
        (errSecItemNotFound, nil)
    }

    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        errSecSuccess
    }

    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        errSecSuccess
    }
}

/// A read that shows a popup and blocks until the test answers it.
private final class OpenPopupItemAccessor: SecurityItemAccessing, Sendable {
    private let shown = DispatchSemaphore(value: 0)
    private let answered = DispatchSemaphore(value: 0)

    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        shown.signal()
        answered.wait()
        return (errSecSuccess, Data("login".utf8))
    }

    func waitUntilShown() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [shown] in
                shown.wait()
                continuation.resume()
            }
        }
    }

    func answer() {
        answered.signal()
    }

    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) {
        (errSecItemNotFound, nil)
    }

    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        errSecSuccess
    }

    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        errSecSuccess
    }
}
