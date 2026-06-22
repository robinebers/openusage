import XCTest
@testable import OpenUsage

/// A `ProcessRunning` whose behavior is fully scripted per call, so tests can control which
/// commands "exist" (`--version` probes) and how the actual ccusage query resolves per runner.
private final class ScriptedProcessRunner: ProcessRunning, @unchecked Sendable {
    var calls: [(executable: String, arguments: [String])] = []
    private let handler: (String, [String]) throws -> ProcessResult

    init(_ handler: @escaping (String, [String]) throws -> ProcessResult) {
        self.handler = handler
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        calls.append((executable, arguments))
        return try handler(executable, arguments)
    }

    /// Commands (by basename) that report a successful `--version`.
    static func versionsAvailable(_ available: Set<String>, queryStdout: String = "[]") -> ScriptedProcessRunner {
        ScriptedProcessRunner { executable, arguments in
            let name = (executable as NSString).lastPathComponent
            if arguments == ["--version"] {
                let ok = available.contains(name)
                return ProcessResult(exitCode: ok ? 0 : 127, stdout: ok ? "1.0.0" : "", stderr: ok ? "" : "not found")
            }
            return ProcessResult(exitCode: 0, stdout: queryStdout, stderr: "")
        }
    }
}

final class CcusageRunnerTests: XCTestCase {
    private let okJSON = #"{ "daily": [{ "date": "2026-02-20", "totalTokens": 150, "totalCost": 0.25 }] }"#

    // MARK: - Output parsing

    func testParsesArrayOutput() {
        let usage = CcusageRunner.parseOutput("""
        [
          { "date": "2026-02-20", "totalTokens": 150, "costUSD": 0.75 }
        ]
        """)

        XCTAssertEqual(usage?.daily.first?.date, "2026-02-20")
        XCTAssertEqual(usage?.daily.first?.totalTokens, 150)
        XCTAssertEqual(usage?.daily.first?.costUSD, 0.75)
    }

    func testParsesObjectOutputAfterNoise() {
        let usage = CcusageRunner.parseOutput("""
        loading
        { "daily": [{ "date": "2026-02-20", "totalTokens": 150, "totalCost": 0.75 }] }
        """)

        XCTAssertEqual(usage?.daily.first?.totalTokens, 150)
        XCTAssertEqual(usage?.daily.first?.costUSD, 0.75)
    }

    // MARK: - Argument vectors per runner kind

    func testRunnerArgsBunx() {
        XCTAssertEqual(
            CcusageRunner.runnerArgs(kind: .bunx, provider: .claude, since: "20260101"),
            ["--silent", "ccusage@20.0.2", "claude", "daily", "--json", "--order", "desc", "--since", "20260101"]
        )
    }

    func testRunnerArgsPnpmDlx() {
        XCTAssertEqual(
            CcusageRunner.runnerArgs(kind: .pnpmDlx, provider: .claude, since: "20260101"),
            ["-s", "dlx", "ccusage@20.0.2", "claude", "daily", "--json", "--order", "desc", "--since", "20260101"]
        )
    }

    func testRunnerArgsYarnDlx() {
        XCTAssertEqual(
            CcusageRunner.runnerArgs(kind: .yarnDlx, provider: .codex, since: "20260101"),
            ["dlx", "-q", "ccusage@20.0.2", "codex", "daily", "--json", "--order", "desc", "--since", "20260101"]
        )
    }

    func testRunnerArgsNpmExec() {
        XCTAssertEqual(
            CcusageRunner.runnerArgs(kind: .npmExec, provider: .claude, since: "20260101"),
            ["exec", "--yes", "--package=ccusage@20.0.2", "--", "ccusage", "claude", "daily", "--json", "--order", "desc", "--since", "20260101"]
        )
    }

    func testRunnerArgsNpx() {
        XCTAssertEqual(
            CcusageRunner.runnerArgs(kind: .npx, provider: .codex, since: "20260101"),
            ["--yes", "ccusage@20.0.2", "codex", "daily", "--json", "--order", "desc", "--since", "20260101"]
        )
    }

    // MARK: - Runner candidates

    func testBunxCandidatesIncludeBunHomeAndBareName() {
        let candidates = CcusageRunner.runnerCandidates(.bunx, home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(candidates.first, "/Users/test/.bun/bin/bunx")
        XCTAssertEqual(candidates.last, "bunx")
    }

    // MARK: - nvm default alias resolution

    func testNvmDefaultBinPathWithVPrefix() throws {
        let home = try makeTempHome()
        try writeNvmAlias("v22.16.0", home: home)
        XCTAssertEqual(
            CcusageRunner.nvmDefaultBinPath(home: home),
            home.appendingPathComponent(".nvm/versions/node/v22.16.0/bin").path
        )
    }

    func testNvmDefaultBinPathWithoutVPrefix() throws {
        let home = try makeTempHome()
        try writeNvmAlias("22.16.0", home: home)
        XCTAssertEqual(
            CcusageRunner.nvmDefaultBinPath(home: home),
            home.appendingPathComponent(".nvm/versions/node/v22.16.0/bin").path
        )
    }

    func testNvmDefaultBinPathMissingAliasReturnsNil() throws {
        let home = try makeTempHome()
        XCTAssertNil(CcusageRunner.nvmDefaultBinPath(home: home))
    }

    func testNvmDefaultBinPathFollowsAliasIndirection() throws {
        // `default` -> `node` -> `v20.11.0`
        let home = try makeTempHome()
        try writeNvmAlias("node", home: home, named: "default")
        try writeNvmAlias("v20.11.0", home: home, named: "node")
        XCTAssertEqual(
            CcusageRunner.nvmDefaultBinPath(home: home),
            home.appendingPathComponent(".nvm/versions/node/v20.11.0/bin").path
        )
    }

    func testNvmDefaultBinPathReturnsNilForUnresolvableMetaAlias() throws {
        // `lts/*` isn't a plain alias file, so it can't be resolved to a version here.
        let home = try makeTempHome()
        try writeNvmAlias("lts/*", home: home, named: "default")
        XCTAssertNil(CcusageRunner.nvmDefaultBinPath(home: home))
    }

    // MARK: - PATH enrichment

    func testPathEntriesIncludeVersionManagerDirsAndDedupe() throws {
        let home = try makeTempHome()
        try writeNvmAlias("22.16.0", home: home)
        let existing = "/opt/homebrew/bin:/usr/bin:/bin"
        let entries = CcusageRunner.pathEntries(home: home, existingPath: existing)

        XCTAssertEqual(entries.first, home.appendingPathComponent(".bun/bin").path)
        XCTAssertTrue(entries.contains(home.appendingPathComponent(".nvm/current/bin").path))
        XCTAssertTrue(entries.contains(home.appendingPathComponent(".nvm/versions/node/v22.16.0/bin").path))
        XCTAssertTrue(entries.contains(home.appendingPathComponent(".local/bin").path))
        XCTAssertTrue(entries.contains("/usr/bin"))
        // De-duped: /opt/homebrew/bin appears once even though it's in both the defaults and PATH.
        XCTAssertEqual(entries.filter { $0 == "/opt/homebrew/bin" }.count, 1)
    }

    // MARK: - Resolution & fallback

    func testCollectRunnersFallsBackToNpxWhenBunxAbsent() {
        let runner = CcusageRunner(
            processRunner: ScriptedProcessRunner.versionsAvailable(["npx"]),
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            isExecutable: { _ in false }
        )
        XCTAssertEqual(runner.collectRunners().map(\.kind), [.npx])
    }

    func testCollectRunnersResolvesAbsolutePathWithoutProbing() {
        let bunxPath = "/opt/homebrew/bin/bunx"
        let probe = ScriptedProcessRunner.versionsAvailable([]) // nothing probes successfully
        let runner = CcusageRunner(
            processRunner: probe,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            isExecutable: { $0 == bunxPath }
        )
        let runners = runner.collectRunners()
        XCTAssertEqual(runners.map(\.kind), [.bunx])
        XCTAssertEqual(runners.first?.program, bunxPath)
        // An absolute hit must not be probed with `--version`.
        XCTAssertFalse(probe.calls.contains { $0.arguments == ["--version"] && $0.executable == bunxPath })
    }

    func testQueryReturnsNoRunnerWhenNothingResolves() async {
        let runner = CcusageRunner(
            processRunner: ScriptedProcessRunner.versionsAvailable([]),
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            isExecutable: { _ in false }
        )
        let result = await runner.query(provider: .claude, since: "20260101")
        XCTAssertEqual(result, .failure(.noRunner))
    }

    func testQuerySucceedsViaNpxWhenBunxAbsent() async throws {
        let runner = CcusageRunner(
            processRunner: ScriptedProcessRunner.versionsAvailable(["npx"], queryStdout: okJSON),
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            isExecutable: { _ in false }
        )
        let usage = try await runner.query(provider: .claude, since: "20260101").get()
        XCTAssertEqual(usage.daily.first?.date, "2026-02-20")
        XCTAssertEqual(usage.daily.first?.totalTokens, 150)
        XCTAssertEqual(usage.daily.first?.costUSD, 0.25)
    }

    func testQueryFallsThroughToNextRunnerWhenFirstFails() async throws {
        let okJSON = self.okJSON
        // bunx + npx both resolve; bunx's query exits non-zero, npx's succeeds.
        let scripted = ScriptedProcessRunner { executable, arguments in
            let name = (executable as NSString).lastPathComponent
            if arguments == ["--version"] {
                let ok = name == "bunx" || name == "npx"
                return ProcessResult(exitCode: ok ? 0 : 127, stdout: ok ? "1.0.0" : "", stderr: "")
            }
            if name == "bunx" {
                return ProcessResult(exitCode: 1, stdout: "", stderr: "bunx boom")
            }
            return ProcessResult(exitCode: 0, stdout: okJSON, stderr: "")
        }
        let runner = CcusageRunner(
            processRunner: scripted,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            isExecutable: { _ in false }
        )

        let usage = try await runner.query(provider: .claude, since: "20260101").get()
        XCTAssertEqual(usage.daily.first?.totalTokens, 150)
        // The query was attempted on bunx first, then fell through to npx.
        let queryRunners = scripted.calls.filter { $0.arguments != ["--version"] }.map { ($0.executable as NSString).lastPathComponent }
        XCTAssertEqual(queryRunners, ["bunx", "npx"])
    }

    func testQueryStopsAtTimeoutWithoutTryingFallbackRunners() async {
        // bunx + npx both resolve; bunx times out — npx must NOT be attempted.
        let scripted = ScriptedProcessRunner { executable, arguments in
            let name = (executable as NSString).lastPathComponent
            if arguments == ["--version"] {
                let ok = name == "bunx" || name == "npx"
                return ProcessResult(exitCode: ok ? 0 : 127, stdout: ok ? "1.0.0" : "", stderr: "")
            }
            if name == "bunx" {
                throw ProcessRunnerError.timedOut(executable: executable, timeout: 15)
            }
            return ProcessResult(exitCode: 0, stdout: "[]", stderr: "")
        }
        let runner = CcusageRunner(
            processRunner: scripted,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            isExecutable: { _ in false }
        )

        let result = await runner.query(provider: .claude, since: "20260101")
        XCTAssertEqual(result, .failure(.timedOut))
        let queryRunners = scripted.calls.filter { $0.arguments != ["--version"] }.map { ($0.executable as NSString).lastPathComponent }
        XCTAssertEqual(queryRunners, ["bunx"])
    }

    // MARK: - Lazy resolution & session cache (no wasted spawns)

    func testQueryIssuesNoWastedProbeSpawns() async {
        // bunx resolves via its absolute path (no `--version` probe); lazy resolution stops there and
        // runs ccusage. The old eager `collectRunners()` also probed pnpm/yarn/npm/npx — those wasted
        // probe spawns are gone, so the only spawn is the ccusage query itself.
        let scripted = ScriptedProcessRunner.versionsAvailable(["bunx"], queryStdout: okJSON)
        let runner = CcusageRunner(
            processRunner: scripted,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            isExecutable: { $0 == "/opt/homebrew/bin/bunx" }
        )

        _ = await runner.query(provider: .claude, since: "20260101")

        XCTAssertEqual(scripted.calls.count, 1)
        XCTAssertFalse(scripted.calls.contains { $0.arguments == ["--version"] })
    }

    func testRepeatedQueriesReuseResolvedRunnerWithoutReprobing() async {
        // bunx only on PATH (resolved via a bare-name `--version` probe), so the first query probes
        // once then runs ccusage. The second query reuses the cached runner and only runs ccusage —
        // no fresh probe — which is what keeps the 5-minute refresh loop from re-probing every pass.
        let scripted = ScriptedProcessRunner.versionsAvailable(["bunx"], queryStdout: okJSON)
        let runner = CcusageRunner(
            processRunner: scripted,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            isExecutable: { _ in false }
        )

        _ = await runner.query(provider: .claude, since: "20260101")
        let afterFirst = scripted.calls.count
        _ = await runner.query(provider: .codex, since: "20260101")

        XCTAssertEqual(afterFirst, 2)                                      // probe + run
        XCTAssertEqual(scripted.calls.count, 3)                           // + cached run only
        XCTAssertEqual(scripted.calls.filter { $0.arguments == ["--version"] }.count, 1)
    }

    func testCachedRunnerFailureFallsBackWithoutRerunningIt() async throws {
        let okJSON = self.okJSON
        // bunx + npx both resolvable. Warm the cache with a bunx success, then make bunx fail: the
        // next query must fall back to npx WITHOUT re-running the just-failed bunx a second time in the
        // same pass (the double-run the fast path would otherwise cause).
        final class Flag: @unchecked Sendable { var bunxFails = false }
        let flag = Flag()
        let scripted = ScriptedProcessRunner { executable, arguments in
            let name = (executable as NSString).lastPathComponent
            if arguments == ["--version"] {
                let ok = name == "bunx" || name == "npx"
                return ProcessResult(exitCode: ok ? 0 : 127, stdout: ok ? "1.0.0" : "", stderr: "")
            }
            if name == "bunx", flag.bunxFails {
                return ProcessResult(exitCode: 1, stdout: "", stderr: "bunx boom")
            }
            return ProcessResult(exitCode: 0, stdout: okJSON, stderr: "")
        }
        let runner = CcusageRunner(
            processRunner: scripted,
            homeDirectory: { URL(fileURLWithPath: "/Users/test") },
            isExecutable: { _ in false }
        )

        _ = try await runner.query(provider: .claude, since: "20260101").get()  // caches bunx
        flag.bunxFails = true
        scripted.calls.removeAll()
        let usage = try await runner.query(provider: .codex, since: "20260101").get()

        XCTAssertEqual(usage.daily.first?.totalTokens, 150)                 // recovered via npx
        let bunxRuns = scripted.calls.filter {
            ($0.executable as NSString).lastPathComponent == "bunx" && $0.arguments != ["--version"]
        }
        XCTAssertEqual(bunxRuns.count, 1, "the just-failed cached runner must not be re-run this pass")
    }

    // MARK: - Helpers

    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-runner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func writeNvmAlias(_ value: String, home: URL, named name: String = "default") throws {
        let aliasDir = home.appendingPathComponent(".nvm/alias")
        try FileManager.default.createDirectory(at: aliasDir, withIntermediateDirectories: true)
        try (value + "\n").write(to: aliasDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
