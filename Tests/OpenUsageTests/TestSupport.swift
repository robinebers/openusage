import AppKit
import SwiftUI
import XCTest
import os
@testable import OpenUsage

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    var response: HTTPResponse
    var requests: [HTTPRequest] = []

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }
}

final class RoutingHTTPClient: HTTPClient, @unchecked Sendable {
    private let requestsLock = OSAllocatedUnfairLock(initialState: [HTTPRequest]())
    var requests: [HTTPRequest] { requestsLock.withLock { $0 } }
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestsLock.withLock { $0.append(request) }
        return try await handler(request)
    }
}

extension HTTPRequest {
    /// Claude's hourly reset-grants check, which shares the usage endpoint's path.
    var isClaudeResetGrantsCheck: Bool { url.query?.contains("cedar_ember=1") == true }
}

final class TestClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date.distantPast)

    init(_ value: Date) { set(value) }

    var now: Date { lock.withLock { $0 } }

    func set(_ value: Date) { lock.withLock { $0 = value } }
}

final class TestSwitch<Value: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }

    var value: Value {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

@MainActor
final class StubRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    var answer: @MainActor (Int) -> Result<ProviderSnapshot, RefreshFailure>
    private(set) var refreshCount = 0

    init(provider: Provider, descriptors: [WidgetDescriptor], answer: @escaping @MainActor (Int) -> Result<ProviderSnapshot, RefreshFailure>) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.answer = answer
    }

    convenience init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.init(provider: provider, descriptors: descriptors) { _ in .success(snapshot) }
    }

    convenience init(provider: Provider, descriptors: [WidgetDescriptor], failure: RefreshFailure) {
        self.init(provider: provider, descriptors: descriptors) { _ in .failure(failure) }
    }

    convenience init(provider: Provider, descriptors: [WidgetDescriptor], results: [Result<ProviderSnapshot, RefreshFailure>]) {
        self.init(provider: provider, descriptors: descriptors) { results[min($0, results.count - 1)] }
    }

    func refresh() async -> Result<ProviderSnapshot, RefreshFailure> {
        defer { refreshCount += 1 }
        return answer(refreshCount)
    }
}

extension Result where Success == ProviderSnapshot, Failure == RefreshFailure {
    var failure: RefreshFailure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}

@MainActor
final class HangingProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private(set) var wasCancelled = false

    init(provider: Provider, descriptors: [WidgetDescriptor]) {
        self.provider = provider
        self.widgetDescriptors = descriptors
    }

    func refresh() async -> Result<ProviderSnapshot, RefreshFailure> {
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            wasCancelled = true
        }
        return .failure(RefreshFailure(message: "hung", kind: .refused))
    }
}

@MainActor
final class RecordingTelemetrySink: TelemetrySink {
    var events: [(name: String, properties: [String: Any])] = []
    func capture(_ event: String, _ properties: [String: Any]) { events.append((event, properties)) }
    func flush() {}
    func events(named name: String) -> [[String: Any]] {
        events.filter { $0.name == name }.map(\.properties)
    }
}

extension AppContainer {
    static func forTesting(
        accounts: AccountStore,
        defaults: UserDefaults,
        http: any HTTPClient = URLSessionHTTPClient(),
        telemetry: RecordingTelemetrySink = RecordingTelemetrySink()
    ) -> AppContainer {
        AppContainer(
            accounts: accounts,
            defaults: defaults,
            http: http,
            telemetry: telemetry,
            telemetryDefaults: defaults
        )
    }
}

extension WidgetDataStore {
    static func forTesting(
        _ runtimes: [ProviderRuntime],
        registry: WidgetRegistry? = nil,
        cache: ProviderSnapshotCache? = nil,
        defaults: UserDefaults,
        now: @escaping () -> Date = Date.init,
        providerRefreshTimeout: TimeInterval = WidgetDataStore.defaultProviderRefreshTimeout
    ) -> WidgetDataStore {
        WidgetDataStore(
            registry: registry ?? .from(runtimes),
            providers: runtimes,
            cache: cache ?? ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            now: now,
            providerRefreshTimeout: providerRefreshTimeout
        )
    }
}

final class InMemoryCredentialVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [UUID: AccountCredential] = [:]

    func load(_ id: UUID) throws -> AccountCredential? {
        lock.lock()
        defer { lock.unlock() }
        return credentials[id]
    }

    func save(_ credential: AccountCredential, for id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        credentials[id] = credential
    }

    func update(_ credential: AccountCredential, for id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard credentials[id] != nil else { throw CredentialVaultError.missingCredential }
        credentials[id] = credential
    }

    func delete(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        credentials.removeValue(forKey: id)
    }
}

@MainActor
func scrollViews(in view: NSView) -> [NSScrollView] {
    [view as? NSScrollView].compactMap { $0 } + view.subviews.flatMap(scrollViews)
}

struct HostedPopover {
    let panel: QuietMenuBarPanel
    let host: NSView
    let popover: PopoverState
    let defaults: UserDefaults

    @MainActor
    func open() async throws {
        popover.popoverShown = true
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
    }
}

extension QuietWindowTestCase {
    /// The popover as `StatusItemController` hosts it, on its dashboard, one Claude account of two rows
    /// per label, in an offscreen panel. Motion is on whatever the Mac's Reduce Motion setting (the CI
    /// runner image turns it on), since the tests watch the slide and the morph. The caller installs a
    /// height bridge on `MenuBarPopover`, cleared when the test ends, and then calls `open()`.
    func hostPopover(accounts labels: [String]) async throws -> HostedPopover {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        let ids = labels.map { store.add(kind: .claude, label: $0, credential: .apiKey("key")).cardID }
        for _ in 0..<400 where container.layout.displayGroups.count < ids.count { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(container.layout.displayGroups.count, ids.count, "the accounts never reached the dashboard")
        for id in ids {
            container.dataStore.snapshots[id] = ProviderSnapshot(
                providerID: id, displayName: "Claude", plan: "Max 20x",
                lines: ["Session", "Weekly"].map {
                    .progress(label: $0, used: 30, limit: 100, format: .percent, resetsAt: Date().addingTimeInterval(3600), periodDurationMs: 5 * 3_600_000)
                }
            )
        }
        let hosting = NSHostingController(rootView: AnyView(
            DashboardView()
                .environment(\.reduceAnimations, false)
                .environment(container)
                .environment(container.layout)
                .environment(container.popover)
                .environment(container.dataStore)
                .environment(container.renaming)
                .environment(UpdaterController())
                .environment(\.colorScheme, .light)
        ))
        let panel = QuietMenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelHeightController.defaultHeight))
        panel.appearance = NSAppearance(named: .aqua)
        let host = hosting.view
        host.wantsLayer = true
        host.layerContentsRedrawPolicy = .duringViewResize
        panel.contentViewController = hosting
        addTeardownBlock {
            MenuBarPopover.applyHeight = nil
            MenuBarPopover.clampHeight = nil
        }
        QuietTestProcess.show(panel, in: self)
        return HostedPopover(panel: panel, host: host, popover: container.popover, defaults: defaults)
    }
}

extension XCTestCase {
    func isolatedDefaults() -> UserDefaults {
        let suite = "\(type(of: self)).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
}
