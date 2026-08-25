import XCTest
@testable import OpenUsage

/// The shipped pricing resources (supplement + LiteLLM/models.dev snapshots) as a ready-to-use
/// `ModelPricing` — loaded once, entirely offline (no store, no network, no disk cache). Tests that
/// price real model names use this the way production code uses `ModelPricingStore.current()`.
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

/// Builds throwaway Claude config dirs (`<tmp>/…/projects/<file>.jsonl`) and canned usage lines for
/// `ClaudeLogUsageScanner` tests, plus a scanner wired to read only the fixture (never the real
/// `~/.claude` of the machine running the tests).
enum ClaudeLogFixture {
    /// A temp Claude config dir whose `projects/` contains `files` (relative path → JSONL content).
    static func makeHome(files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-claude-\(UUID().uuidString)", isDirectory: true)
        try write(files: files, toProjectsOf: root)
        return root
    }

    /// A temp *user home* fixture for Cowork tests. `claudeFiles` land under
    /// `<home>/.claude/projects/`; each `coworkSessions` entry (session dir relative to
    /// `local-agent-mode-sessions`, e.g. `group/sub/local_x` → files) lands under that session's
    /// `.claude/projects/` inside `<home>/Library/Application Support/Claude/local-agent-mode-sessions`.
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

    /// A scanner pinned to the fixture home (or to nothing when `home` is nil → "No data").
    static func scanner(home: URL?) -> ClaudeLogUsageScanner {
        ClaudeLogUsageScanner(
            environment: FakeEnvironment(home.map { ["CLAUDE_CONFIG_DIR": $0.path] } ?? [:]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-claude-home") },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        )
    }

    /// A scanner whose *user home* is the fixture from `makeUserHome` — exercises the default
    /// `~/.claude` root plus Cowork session discovery, with no `CLAUDE_CONFIG_DIR` override.
    static func scanner(userHome: URL) -> ClaudeLogUsageScanner {
        ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { userHome },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        )
    }

    /// One Claude Code usage line in the modern log shape. Pass `nil` to omit a field.
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

/// Builds throwaway Codex homes (`<tmp>/…/sessions/<file>.jsonl`) and canned rollout lines for
/// `CodexLogUsageScanner` tests, plus a scanner pinned to the fixture (never the real `~/.codex`).
enum CodexLogFixture {
    /// A temp Codex home whose `sessions/` (or another top-level dir) contains `files`
    /// (relative path → JSONL content).
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

    /// A scanner pinned to the fixture home (or to nothing when `home` is nil → "No data").
    static func scanner(home: URL?) -> CodexLogUsageScanner {
        CodexLogUsageScanner(
            environment: FakeEnvironment(home.map { ["CODEX_HOME": $0.path] } ?? [:]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-codex-home") },
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>()
        )
    }

    /// A `turn_context` line carrying the session's active model.
    static func turnContext(timestamp: String, model: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "turn_context",
            "payload": ["model": model]
        ])
    }

    /// An `event_msg`/`token_count` line. Pass `last` for the turn delta and/or `totals` for the
    /// cumulative counter; either may be omitted like in real rollouts.
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

    /// Token-count dictionary in the rollout shape.
    static func usage(input: Int, cached: Int = 0, output: Int, reasoning: Int = 0) -> [String: Int] {
        [
            "input_tokens": input,
            "cached_input_tokens": cached,
            "output_tokens": output,
            "reasoning_output_tokens": reasoning,
            "total_tokens": input + output
        ]
    }

    /// An `event_msg`/`thread_settings_applied` line carrying the session's service tier, the way
    /// Codex CLI ≥ July 2026 records tier changes.
    static func threadSettingsApplied(timestamp: String, serviceTier: String, model: String = "gpt-5.2") -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "thread_settings_applied",
                "thread_settings": ["model": model, "service_tier": serviceTier]
            ]
        ])
    }

    /// A `session_meta` line marking the file as a `thread_spawn` subagent session.
    static func subagentSessionMeta(timestamp: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": "subagent-abc", "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent-xyz"]]]]
        ])
    }

    /// A `session_meta` line marking the file as a fork (`forked_from_id`, no subagent source).
    static func forkSessionMeta(timestamp: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": "fork-abc", "forked_from_id": "parent-xyz"]
        ])
    }

    /// A root session's `session_meta` line (no parent, nothing replayed).
    static func rootSessionMeta(timestamp: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": "root-abc", "source": "vscode"]
        ])
    }

    /// An `event_msg`/`task_started` line. `startedAt` is the turn's start as epoch seconds — a
    /// replayed parent turn keeps its original (older) value; a live turn is at/after the child
    /// session's creation.
    static func taskStarted(timestamp: String, startedAt: Int) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "turn-1", "started_at": startedAt]
        ])
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

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

/// Test-target-only default so test doubles don't each need a stub. The app target has no such
/// default on purpose: a real provider must decide its own credential probe (see `FirstRunSeeder`).
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

/// A runtime whose `refresh()` never returns on its own — it waits until it is cancelled. Models the
/// hung provider the refresh deadline exists to bound (a subprocess that never exits, a credential read
/// that blocks). `wasCancelled` records whether the store actually cancelled the work it gave up on.
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
        // Far longer than any test's injected deadline, so the deadline always wins the race. The sleep
        // is cancellable purely so a test can observe the cancellation and the task doesn't outlive it.
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            wasCancelled = true
        }
        return ProviderSnapshot.error(provider: provider, message: "hung")
    }
}

/// A runtime that returns a different snapshot per refresh (then repeats the last), counting calls —
/// for sequences like a success that later turns into a failure, or a failure that recovers, which
/// `CountingProviderRuntime` (one fixed snapshot) can't express.
@MainActor
final class SequenceProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let snapshots: [ProviderSnapshot]
    private(set) var refreshCount = 0

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshots: [ProviderSnapshot]) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshots = snapshots
    }

    func refresh() async -> ProviderSnapshot {
        let snapshot = snapshots[min(refreshCount, snapshots.count - 1)]
        refreshCount += 1
        return snapshot
    }
}

/// An unsigned Cursor-style JWT whose payload carries the `sub`/`exp` claims the auth store parses.
/// Pass `sub: nil` for a token without a subject claim.
func makeCursorJWT(sub: String? = "google-oauth2|user", exp: Double = 9_999_999_999) -> String {
    let payload = sub.map { #"{"sub":"\#($0)","exp":\#(exp)}"# } ?? #"{"exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

/// A key/value-table SQLite stand-in (Cursor's `state.vscdb` shape): `queryValue` returns the value
/// whose key appears in the SQL, and `execute` records `(key, value) VALUES (…)` upserts so tests
/// can assert what was persisted.
final class KeyValueSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    var writtenValues: [String: String] = [:]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func queryValue(path: String, sql: String) throws -> String? {
        for (key, value) in values where sql.contains(key) {
            return value
        }
        return nil
    }

    func execute(path: String, sql: String) throws {
        guard let key = sqlValue(after: "(key, value) VALUES ('", in: sql),
              let value = sqlValue(after: "', '", in: sql)
        else {
            return
        }
        writtenValues[key] = value
    }

    private func sqlValue(after marker: String, in sql: String) -> String? {
        guard let start = sql.range(of: marker)?.upperBound,
              let end = sql[start...].range(of: "'")?.lowerBound
        else {
            return nil
        }
        return String(sql[start..<end]).replacingOccurrences(of: "''", with: "'")
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
