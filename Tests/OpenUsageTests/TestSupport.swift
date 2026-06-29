import XCTest
@testable import OpenUsage

/// Shared test doubles used across provider and store tests.
struct FakeEnvironment: EnvironmentReading {
    var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func value(for name: String) -> String? {
        values[name]
    }
}

final class FakeFiles: TextFileAccessing, @unchecked Sendable {
    var files: [String: String]

    init(_ files: [String: String] = [:]) {
        self.files = files
    }

    func exists(_ path: String) -> Bool {
        files[path] != nil
    }

    func readText(_ path: String) throws -> String {
        files[path] ?? ""
    }

    func writeText(_ path: String, _ text: String) throws {
        files[path] = text
    }

    func remove(_ path: String) throws {
        files.removeValue(forKey: path)
    }
}

final class FakeKeychain: KeychainAccessing, @unchecked Sendable {
    var value: String?

    init(_ value: String? = nil) {
        self.value = value
    }

    func readGenericPassword(service: String) throws -> String? {
        value
    }

    func writeGenericPassword(service: String, value: String) throws {
        self.value = value
    }
}

final class ServiceKeychain: KeychainAccessing, @unchecked Sendable {
    var values: [String: String]
    var currentUserValues: [String: String]

    init(values: [String: String] = [:], currentUserValues: [String: String] = [:]) {
        self.values = values
        self.currentUserValues = currentUserValues
    }

    func readGenericPassword(service: String) throws -> String? {
        values[service]
    }

    func writeGenericPassword(service: String, value: String) throws {
        values[service] = value
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        currentUserValues[service]
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        currentUserValues[service] = value
    }
}

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

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    var lastCcusageEnvironment: [String: String]?

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        if arguments == ["--version"] {
            return ProcessResult(exitCode: 0, stdout: "1.0.0\n", stderr: "")
        }
        lastCcusageEnvironment = environment
        return ProcessResult(
            exitCode: 0,
            stdout: """
            { "daily": [{ "date": "2026-02-20", "totalTokens": 150, "totalCost": 0.25 }] }
            """,
            stderr: ""
        )
    }
}

@MainActor
final class TestProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    let snapshot: ProviderSnapshot

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        snapshot
    }
}

@MainActor
final class CountingProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    let snapshot: ProviderSnapshot
    var refreshCount = 0

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        refreshCount += 1
        return snapshot
    }
}

/// A runtime that returns `first` on the first refresh and `second` on every refresh after — for
/// sequences like a success that later turns into a failure (e.g. testing that a hard error takes
/// precedence over a stale soft warning from the prior success).
@MainActor
final class TogglingProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let first: ProviderSnapshot
    private let second: ProviderSnapshot
    private var refreshed = false

    init(provider: Provider, descriptors: [WidgetDescriptor], first: ProviderSnapshot, second: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.first = first
        self.second = second
    }

    func refresh() async -> ProviderSnapshot {
        if refreshed { return second }
        refreshed = true
        return first
    }
}

/// Routes each request through a handler and records every request — for multi-request flows like
/// the 401 → token refresh → retry sequence, where a single canned response can't express the flow.
final class RoutingHTTPClient: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try await handler(request)
    }
}
