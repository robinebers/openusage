import XCTest
@testable import OpenUsage

@MainActor
final class FirstLaunchSetupTests: XCTestCase {
    // MARK: - When the welcome screen shows

    func testInterruptedFirstLaunchStaysPendingUntilCleared() throws {
        let defaults = try makeDefaults()
        XCTAssertFalse(FirstLaunchSetup.needsSetup(defaults: defaults))
        FirstLaunchSetup.markPending(defaults: defaults)
        XCTAssertTrue(FirstLaunchSetup.needsSetup(defaults: defaults))
        FirstLaunchSetup.clearPending(defaults: defaults)
        XCTAssertFalse(FirstLaunchSetup.needsSetup(defaults: defaults))
    }

    func testFirstLaunchFlagDoesNotCauseLegacySettingsMigration() throws {
        let suite = "FirstLaunchSetupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(SettingsMigrator.isFreshInstall(defaults: defaults, domainName: suite))
        SettingsMigrator.migrate(defaults: defaults, domainName: suite)
        FirstLaunchSetup.markPending(defaults: defaults)
        XCTAssertNil(ProviderEnablementStore(defaults: defaults).enabledIDs)
        XCTAssertTrue(FirstLaunchSetup.needsSetup(defaults: defaults))
    }

    func testNoEnabledProvidersAlwaysNeedsSetupEvenAfterSkipping() throws {
        let defaults = try makeDefaults()
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders([])
        XCTAssertTrue(FirstLaunchSetup.needsSetup(defaults: defaults))
        FirstLaunchSetup.markPending(defaults: defaults)
        enablement.setEnabled(true, for: "claude")
        XCTAssertFalse(FirstLaunchSetup.needsSetup(defaults: defaults))
    }

    // MARK: - Detection

    func testDetectionSelectsDetectedProvidersWithoutConnecting() async throws {
        let file = Stub(id: "file", detected: true)
        let absent = Stub(id: "absent")
        let harness = try Harness([file, absent])

        await harness.setup.detect()

        XCTAssertFalse(harness.setup.isDetecting)
        XCTAssertEqual(harness.setup.selectedIDs, ["file"])
        XCTAssertEqual(harness.setup.visibleChoices.map(\.id), ["file"])
        XCTAssertEqual(file.interactions + absent.interactions, [])
        XCTAssertNil(harness.store, "detection must not build the dashboard")
        harness.setup.showAll = true
        XCTAssertEqual(harness.setup.visibleChoices.count, 2)
    }

    func testLoginAwaitingKeychainApprovalIsDetectedWithoutPrompting() async throws {
        let protected = Stub(id: "protected", detectionRefusal: .permissionNeeded)
        let busy = Stub(id: "busy", detectionRefusal: .busy)
        let harness = try Harness([protected, busy])

        await harness.setup.detect()

        XCTAssertEqual(harness.setup.selectedIDs, ["protected"])
        XCTAssertEqual(protected.detectionInteraction, false)
    }

    // MARK: - Connecting

    func testOnlySelectedProvidersConnectInOrderOneAtATimeWithPermission() async throws {
        let recorder = Recorder()
        let first = Stub(id: "first", detected: true, recorder: recorder)
        let skip = Stub(id: "skip", detected: true, recorder: recorder)
        let last = Stub(id: "last", detected: true, recorder: recorder)
        let harness = try Harness([first, skip, last])
        await harness.setup.detect()
        harness.setup.selectedIDs.remove("skip")

        await harness.setup.connectSelected()

        XCTAssertEqual(recorder.order, ["first", "last"])
        XCTAssertEqual(recorder.maxActive, 1)
        XCTAssertEqual(harness.setup.connectedIDs, ["first", "last"])
        XCTAssertEqual(harness.preparedFamilies, [["first", "last"]])
        XCTAssertEqual(skip.interactions, [])
        XCTAssertEqual(first.interactions, [true])
        XCTAssertEqual(last.interactions, [true])
    }

    func testEveryAccountCardInAFamilyConnects() async throws {
        let main = Stub(id: "claude", detected: true)
        let work = Stub(id: "claude@ab12cd34")
        let harness = try Harness(detecting: [main], dashboard: [main, work])
        await harness.setup.detect()

        await harness.setup.connectSelected()

        XCTAssertEqual(main.interactions, [true])
        XCTAssertEqual(work.interactions, [true])
        XCTAssertEqual(harness.setup.connectedIDs, ["claude"])
    }

    func testDashboardReusesSuccessfulFirstResult() async throws {
        let provider = Stub(id: "test", detected: true)
        let harness = try Harness([provider])
        await harness.setup.detect()
        await harness.setup.connectSelected()

        let outcome = await harness.store?.refresh(providerID: "test")

        XCTAssertEqual(outcome, .cacheHit)
        XCTAssertEqual(provider.interactions.count, 1)
    }

    func testNetworkFailureKeepsProviderOnWithoutImmediateRefetch() async throws {
        let provider = Stub(id: "test", detected: true)
        provider.result = .network
        let harness = try Harness([provider])
        await harness.setup.detect()

        await harness.setup.connectSelected()

        XCTAssertEqual(harness.setup.connectedIDs, ["test"])
        XCTAssertEqual(harness.setup.choices[0].connection, .usageUnavailable)
        XCTAssertFalse(harness.setup.hasFailures)
        let outcome = await harness.store?.refresh(providerID: "test")
        XCTAssertEqual(outcome, .backedOff)
        XCTAssertEqual(provider.interactions.count, 1)
    }

    func testDeniedAccessStaysOffUntilExplicitRetry() async throws {
        let provider = Stub(id: "protected", detected: true)
        provider.result = .denied
        let harness = try Harness([provider])
        await harness.setup.detect()

        await harness.setup.connectSelected()

        XCTAssertTrue(harness.setup.connectedIDs.isEmpty)
        XCTAssertEqual(harness.setup.choices[0].connection, .failed(FirstLaunchSetup.accessDeniedMessage))
        provider.result = .success
        await harness.setup.connectSelected()
        XCTAssertEqual(provider.interactions, [true, true])
        XCTAssertEqual(harness.setup.connectedIDs, ["protected"])
        XCTAssertFalse(harness.setup.hasFailures)
        XCTAssertEqual(harness.preparedFamilies.count, 1, "retry reuses the prepared dashboard")
    }

    func testBusyKeychainIsNotShownAsDenied() async throws {
        let provider = Stub(id: "test", detected: true)
        provider.result = .busy
        let harness = try Harness([provider])
        await harness.setup.detect()

        await harness.setup.connectSelected()

        XCTAssertEqual(harness.setup.choices[0].connection,
                       .failed(KeychainAccessError.busy.errorDescription ?? ""))
    }

    func testRefusalDoesNotHideAProviderNetworkError() async throws {
        let provider = Stub(id: "test", detected: true)
        provider.result = .networkAfterRefusal
        let harness = try Harness([provider])
        await harness.setup.detect()

        await harness.setup.connectSelected()

        XCTAssertEqual(harness.setup.choices[0].connection, .usageUnavailable)
    }

    func testForceRefreshDoesNotAuthorizeKeychainByItself() async {
        let provider = Stub(id: "test")
        _ = await ProviderRefreshDeadline.snapshot(from: provider, timeout: 1)
        _ = await ProviderRefreshDeadline.snapshot(from: provider, timeout: 1, allowsKeychainInteraction: true)
        XCTAssertEqual(provider.interactions, [false, true])
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> UserDefaults {
        let suite = "FirstLaunchSetupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Builds the setup with a `prepare` that mirrors the app: a data store over the dashboard's
    /// runtimes, with the chosen families turned on.
    @MainActor
    private final class Harness {
        private(set) var setup: FirstLaunchSetup!
        private(set) var store: WidgetDataStore?
        private(set) var preparedFamilies: [Set<String>] = []

        convenience init(_ providers: [Stub]) throws {
            try self.init(detecting: providers, dashboard: providers)
        }

        init(detecting: [Stub], dashboard: [Stub]) throws {
            let suite = "FirstLaunchSetupTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            setup = FirstLaunchSetup(providers: detecting) { [unowned self] families in
                preparedFamilies.append(families)
                let enabled = Set(dashboard.map(\.provider.id).filter {
                    families.contains(ProviderAccountID.family(of: $0))
                })
                let store = WidgetDataStore(
                    registry: WidgetRegistry(providers: dashboard.map(\.provider), descriptors: []),
                    providers: dashboard, cache: ProviderSnapshotCache(userDefaults: defaults),
                    defaults: defaults, isProviderEnabled: { enabled.contains($0) }
                )
                self.store = store
                return store
            }
        }
    }

    private final class Recorder {
        var order: [String] = []
        var active = 0
        var maxActive = 0
    }

    private final class Stub: ProviderRuntime {
        enum Result { case success, network, denied, busy, networkAfterRefusal }

        let provider: Provider
        var widgetDescriptors: [WidgetDescriptor] { [] }
        let detected: Bool
        let detectionRefusal: KeychainAccessError?
        let recorder: Recorder?
        var result = Result.success
        var interactions: [Bool] = []
        var detectionInteraction: Bool?

        init(id: String, detected: Bool = false, detectionRefusal: KeychainAccessError? = nil,
             recorder: Recorder? = nil) {
            provider = Provider(id: id, displayName: id, icon: .providerMark(id))
            self.detected = detected
            self.detectionRefusal = detectionRefusal
            self.recorder = recorder
        }

        func hasLocalCredentials() async -> Bool {
            detectionInteraction = await loadOffMainActor { KeychainAccessContext.allowsInteraction }
            if let detectionRefusal { KeychainAccessContext.current?.record(detectionRefusal) }
            return detected
        }

        func refresh() async -> ProviderSnapshot {
            interactions.append(await loadOffMainActor { KeychainAccessContext.allowsInteraction })
            recorder?.order.append(provider.id)
            if let recorder {
                recorder.active += 1
                recorder.maxActive = max(recorder.maxActive, recorder.active)
            }
            await Task.yield()
            if let recorder { recorder.active -= 1 }
            switch result {
            case .success:
                return .make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
            case .network:
                return .error(provider: provider, message: "Temporarily offline", category: .network)
            case .denied:
                KeychainAccessContext.current?.record(.permissionNeeded)
                return .error(provider: provider, message: "Not logged in", category: .notLoggedIn)
            case .busy:
                KeychainAccessContext.current?.record(.busy)
                return .error(provider: provider, message: "Not logged in", category: .notLoggedIn)
            case .networkAfterRefusal:
                KeychainAccessContext.current?.record(.permissionNeeded)
                return .error(provider: provider, message: "Temporarily offline", category: .network)
            }
        }
    }
}
