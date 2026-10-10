import XCTest
@testable import OpenUsage

@MainActor
final class FirstLaunchSetupTests: XCTestCase {
    func testInterruptedFirstLaunchRemainsPendingAfterSettingsExist() throws {
        let suite = "FirstLaunchSetupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(FirstLaunchSetup.needsSetup(isFreshInstall: false, defaults: defaults))
        XCTAssertTrue(FirstLaunchSetup.needsSetup(isFreshInstall: true, defaults: defaults))
        XCTAssertTrue(FirstLaunchSetup.needsSetup(isFreshInstall: false, defaults: defaults))
        defaults.removeObject(forKey: FirstLaunchSetup.pendingKey)
        XCTAssertFalse(FirstLaunchSetup.needsSetup(isFreshInstall: false, defaults: defaults))
    }

    func testDiscoveryDoesNotConnectAndKeepsPermissionOnlyProvidersVisible() async {
        let file = Stub(id: "file", available: true)
        let protected = Stub(id: "protected", needsPermission: true)
        let absent = Stub(id: "absent")
        let setup = FirstLaunchSetup(providers: [file, protected, absent])

        await setup.detect()

        XCTAssertFalse(setup.isDetecting)
        XCTAssertEqual(setup.selectedIDs, ["file", "protected"])
        XCTAssertEqual(setup.visibleChoices.map(\.id), ["file", "protected"])
        XCTAssertEqual(protected.discoveryMode, .discovery)
        XCTAssertEqual(file.refreshes + protected.refreshes + absent.refreshes, 0)
        XCTAssertTrue(setup.choices[1].needsAccess)
        setup.showAll = true
        XCTAssertEqual(setup.visibleChoices.count, 3)
    }

    func testOnlySelectedProvidersConnectInOrderWithExplicitPermission() async {
        let recorder = Recorder()
        let first = Stub(id: "first", available: true, recorder: recorder)
        let skip = Stub(id: "skip", available: true, recorder: recorder)
        let last = Stub(id: "last", available: true, recorder: recorder)
        let setup = FirstLaunchSetup(providers: [first, skip, last])
        await setup.detect()
        setup.selectedIDs.remove("skip")

        await setup.connectSelected()

        XCTAssertEqual(recorder.order, ["first", "last"])
        XCTAssertEqual(recorder.maxActive, 1)
        XCTAssertEqual(setup.connectedIDs, ["first", "last"])
        XCTAssertEqual(skip.refreshes, 0)
        XCTAssertTrue(first.interactive)
        XCTAssertTrue(last.interactive)
    }

    func testDeniedConnectionStaysPendingUntilExplicitRetry() async {
        let provider = Stub(id: "protected", needsPermission: true)
        provider.fail = true
        let setup = FirstLaunchSetup(providers: [provider])
        await setup.detect()

        await setup.connectSelected()
        await Task.yield()

        XCTAssertEqual(provider.refreshes, 1)
        XCTAssertTrue(setup.connectedIDs.isEmpty)
        XCTAssertTrue(setup.hasFailures)
        XCTAssertEqual(setup.choices[0].error, "Access wasn't granted. You can retry or skip for now.")
        provider.fail = false
        await setup.connectSelected()
        XCTAssertEqual(provider.refreshes, 2)
        XCTAssertEqual(setup.connectedIDs, ["protected"])
        XCTAssertFalse(setup.hasFailures)
    }

    func testForceRefreshDoesNotAuthorizeKeychainByItself() async {
        let provider = Stub(id: "test")
        _ = await ProviderRefreshDeadline.snapshot(from: provider, force: true, timeout: 1)
        XCTAssertFalse(provider.interactive)
        _ = await ProviderRefreshDeadline.snapshot(
            from: provider, force: true, timeout: 1, allowsKeychainInteraction: true
        )
        XCTAssertTrue(provider.interactive)
    }

    private final class Recorder {
        var order: [String] = []
        var active = 0
        var maxActive = 0
    }

    private final class Stub: ProviderRuntime {
        let provider: Provider
        var widgetDescriptors: [WidgetDescriptor] { [] }
        let available: Bool
        let needsPermission: Bool
        let recorder: Recorder?
        var fail = false
        var refreshes = 0
        var interactive = false
        var discoveryMode: KeychainAccessContext.Mode?

        init(id: String, available: Bool = false, needsPermission: Bool = false, recorder: Recorder? = nil) {
            provider = Provider(id: id, displayName: id, icon: .providerMark(id))
            self.available = available
            self.needsPermission = needsPermission
            self.recorder = recorder
        }
        func hasLocalCredentials() async -> Bool {
            discoveryMode = KeychainAccessContext.current?.mode
            if needsPermission { KeychainAccessContext.current?.recordPermissionNeeded() }
            return available
        }
        func refresh() async -> ProviderSnapshot {
            refreshes += 1
            interactive = await loadOffMainActor { KeychainAccessContext.allowsInteraction }
            recorder?.order.append(provider.id)
            if let recorder {
                recorder.active += 1
                recorder.maxActive = max(recorder.maxActive, recorder.active)
            }
            await Task.yield()
            if let recorder { recorder.active -= 1 }
            if fail {
                KeychainAccessContext.current?.recordPermissionNeeded()
                return .error(provider: provider, error: KeychainPermissionNeeded())
            }
            return .make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
        }
    }
}
