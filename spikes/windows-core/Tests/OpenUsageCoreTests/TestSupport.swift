import XCTest
@testable import OpenUsageCore

/// The shipped pricing resources (supplement + LiteLLM/models.dev snapshots) as a ready-to-use
/// `ModelPricing` — loaded once, entirely offline (no store, no network, no disk cache).
enum TestPricing {
    static let bundled: ModelPricing = {
        func resource(_ name: String) -> Data {
            guard let url = Bundle.openUsageResources.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else {
                fatalError("bundled resource \(name).json missing")
            }
            return data
        }
        return ModelPricing(
            supplement: try! PricingSupplement.decode(from: resource("pricing_supplement")),
            primary: try! PricingCatalogCodecs.catalogFromCompact(resource("pricing_litellm_snapshot")),
            secondary: try! PricingCatalogCodecs.catalogFromCompact(resource("pricing_models_dev_snapshot"))
        )
    }()
}

/// Builds throwaway Claude config dirs for `ClaudeLogUsageScanner` tests.
enum ClaudeLogFixture {
    static func makeHome(files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-claude-\(UUID().uuidString)", isDirectory: true)
        try write(files: files, toProjectsOf: root)
        return root
    }

    static func makeUserHome(
        claudeFiles: [String: String] = [:],
        coworkSessions: [String: [String: String]] = [:]
    ) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-claude-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if !claudeFiles.isEmpty {
            try write(files: claudeFiles, toProjectsOf: home.appendingPathComponent(".claude"))
        }
        let sessionsBase = home
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        for (sessionDir, files) in coworkSessions {
            try write(
                files: files,
                toProjectsOf: sessionsBase.appendingPathComponent(sessionDir).appendingPathComponent(".claude")
            )
        }
        return home
    }

    private static func write(files: [String: String], toProjectsOf configDir: URL) throws {
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        for (relativePath, content) in files {
            let url = projects.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func scanner(home: URL?) -> ClaudeLogUsageScanner {
        ClaudeLogUsageScanner(
            environment: FakeEnvironment(home.map { ["CLAUDE_CONFIG_DIR": $0.path] } ?? [:]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-claude-home") }
        )
    }

    static func scanner(userHome: URL) -> ClaudeLogUsageScanner {
        ClaudeLogUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { userHome })
    }

    static func usageLine(
        timestamp: String,
        model: String? = "claude-sonnet-4-5-20250929",
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int? = nil,
        cacheRead: Int? = nil,
        costUSD: Double? = nil,
        messageID: String? = "msg_1",
        requestID: String? = "req_1",
        isSidechain: Bool? = nil,
        speed: String? = nil,
        version: String? = "1.0.24"
    ) -> String {
        var usage: [String: Any] = ["input_tokens": input, "output_tokens": output]
        if let cacheWrite { usage["cache_creation_input_tokens"] = cacheWrite }
        if let cacheRead { usage["cache_read_input_tokens"] = cacheRead }
        if let speed { usage["speed"] = speed }
        var message: [String: Any] = ["usage": usage]
        if let model { message["model"] = model }
        if let messageID { message["id"] = messageID }
        var object: [String: Any] = ["timestamp": timestamp, "sessionId": "session-1", "message": message]
        if let version { object["version"] = version }
        if let requestID { object["requestId"] = requestID }
        if let costUSD { object["costUSD"] = costUSD }
        if let isSidechain { object["isSidechain"] = isSidechain }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Builds throwaway Codex homes for `CodexLogUsageScanner` tests.
enum CodexLogFixture {
    static func makeHome(files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true
        )
        for (relativePath, content) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    static func scanner(home: URL?) -> CodexLogUsageScanner {
        CodexLogUsageScanner(
            environment: FakeEnvironment(home.map { ["CODEX_HOME": $0.path] } ?? [:]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-codex-home") }
        )
    }

    static func turnContext(timestamp: String, model: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "turn_context",
            "payload": ["model": model]
        ])
    }

    static func tokenCount(
        timestamp: String,
        last: [String: Int]? = nil,
        totals: [String: Int]? = nil,
        model: String? = nil
    ) -> String {
        var info: [String: Any] = [:]
        if let last { info["last_token_usage"] = last }
        if let totals { info["total_token_usage"] = totals }
        if let model { info["model"] = model }
        return jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": ["type": "token_count", "info": info]
        ])
    }

    static func usage(input: Int, cached: Int = 0, output: Int, reasoning: Int = 0) -> [String: Int] {
        [
            "input_tokens": input,
            "cached_input_tokens": cached,
            "output_tokens": output,
            "reasoning_output_tokens": reasoning,
            "total_tokens": input + output
        ]
    }

    static func subagentSessionMeta(timestamp: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": "subagent-abc", "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent-xyz"]]]]
        ])
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

final class FakeEnvironment: EnvironmentReading, @unchecked Sendable {
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
        guard let text = files[path] else {
            throw NSError(domain: "FakeFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(path)"])
        }
        return text
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

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        value
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        self.value = value
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        value
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

    func readGenericPassword(service: String, account: String) throws -> String? {
        values["\(service):\(account)"] ?? values[service]
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

extension ProviderRuntime {
    func hasLocalCredentials() async -> Bool { false }
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
