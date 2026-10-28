import Foundation
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

/// A mutable clock so a test can advance `now` between refreshes to exercise time-based gates.
final class TestClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date.distantPast)

    init(_ value: Date) { set(value) }

    var now: Date { lock.withLock { $0 } }

    func set(_ value: Date) { lock.withLock { $0 = value } }
}

/// A thread-safe value a stub HTTP handler can read while the test flips it.
final class TestSwitch<Value: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }

    var value: Value {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// A provider runtime that answers each refresh from a script: `answer` gets the refresh's ordinal, so a
/// fixed snapshot, a sequence, a swap between refreshes and a clock-stamped answer are each one closure.
@MainActor
final class StubRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    var answer: @MainActor (Int) -> ProviderSnapshot
    private(set) var refreshCount = 0

    init(provider: Provider, descriptors: [WidgetDescriptor], answer: @escaping @MainActor (Int) -> ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.answer = answer
    }

    convenience init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.init(provider: provider, descriptors: descriptors) { _ in snapshot }
    }

    /// Answers `snapshots` in order and repeats the last one.
    convenience init(provider: Provider, descriptors: [WidgetDescriptor], snapshots: [ProviderSnapshot]) {
        self.init(provider: provider, descriptors: descriptors) { snapshots[min($0, snapshots.count - 1)] }
    }

    func refresh() async -> ProviderSnapshot {
        defer { refreshCount += 1 }
        return answer(refreshCount)
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

    func refresh() async -> ProviderSnapshot {
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            wasCancelled = true
        }
        return ProviderSnapshot(provider: provider, failure: RefreshFailure(message: "hung", kind: .refused))
    }
}

/// Records captured telemetry events without touching PostHog.
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
    /// A container on isolated defaults with a recording telemetry sink; the shape every test uses.
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
    /// A store over `runtimes`, its registry built from them and its snapshot cache on the same defaults;
    /// pass `registry` or `cache` to shape either by hand.
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

extension XCTestCase {
    /// A UserDefaults on a suite of its own, empty now and removed again when the test ends.
    func isolatedDefaults() -> UserDefaults {
        let suite = "\(type(of: self)).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
}
