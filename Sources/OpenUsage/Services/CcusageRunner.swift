import Foundation
import os

enum CcusageProvider: String, Sendable {
    case claude
    case codex
}

/// Package runners we can use to execute `ccusage`, in fallback priority order.
/// Mirrors the Tauri host (`src-tauri/src/plugin_engine/host_api.rs`) so both
/// editions resolve runners identically.
enum CcusageRunnerKind: CaseIterable, Sendable {
    case bunx
    case pnpmDlx
    case yarnDlx
    case npmExec
    case npx

    var label: String {
        switch self {
        case .bunx: return "bunx"
        case .pnpmDlx: return "pnpm dlx"
        case .yarnDlx: return "yarn dlx"
        case .npmExec: return "npm exec"
        case .npx: return "npx"
        }
    }
}

struct CcusageDay: Hashable, Sendable {
    var date: String
    var totalTokens: Int
    var costUSD: Double?
}

struct CcusageDailyUsage: Hashable, Sendable {
    var daily: [CcusageDay]
}

enum CcusageRunnerError: Error, LocalizedError, Equatable {
    case noRunner
    case failed(String)
    case timedOut
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .noRunner:
            return "No package runner found for ccusage. Install Bun, or ensure npm/npx is on your PATH."
        case .failed(let message):
            return message.isEmpty ? "ccusage failed." : message
        case .timedOut:
            return "ccusage timed out."
        case .invalidOutput:
            return "ccusage output was invalid."
        }
    }
}

struct CcusageRunner {
    private static let packageSpec = "ccusage@20.0.2"
    private static let binName = "ccusage"
    private static let timeout: TimeInterval = 15
    private static let probeTimeout: TimeInterval = 2

    var processRunner: ProcessRunning
    var homeDirectory: @Sendable () -> URL
    var isExecutable: @Sendable (String) -> Bool

    /// The runner that last ran `ccusage` successfully, memoized for the session. The periodic
    /// refresh loop calls `query` on a fixed cadence (Claude + Codex, every interval), and runner
    /// resolution never changes mid-session in practice — so caching the winner skips the per-query
    /// `--version` probe spawns that resolution would otherwise repeat on every pass. Lock-backed so
    /// the value-type runner memoizes across calls (and the @MainActor → background hops `query`
    /// makes); cleared on failure so a runner that breaks (toolchain change) is re-resolved next query.
    private let resolved = OSAllocatedUnfairLock<(kind: CcusageRunnerKind, program: String)?>(initialState: nil)

    init(
        processRunner: ProcessRunning = SystemProcessRunner(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.processRunner = processRunner
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
    }

    /// The `--since` argument ccusage expects: `yyyyMMdd`, `daysBack` days before `date`.
    static func sinceString(daysBack: Int, from date: Date) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -daysBack, to: date) ?? date
        let components = Calendar.current.dateComponents([.year, .month, .day], from: since)
        return String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Outcome of running `ccusage` through one resolved runner: success, or a fall-through failure
    /// whose reason becomes the batch's `lastError`. A timeout is thrown (not returned) so the caller
    /// stops trying fallbacks — matching the Tauri host's "skip fallbacks on timeout".
    private enum Attempt {
        case success(CcusageDailyUsage)
        case failed(CcusageRunnerError)
    }

    func query(provider: CcusageProvider, since: String, homePath: String? = nil) async -> Result<CcusageDailyUsage, CcusageRunnerError> {
        let environment = ccusageEnvironment(provider: provider, homePath: homePath)
        var lastError: CcusageRunnerError = .noRunner
        // The cached runner kind already tried (and failed) this pass, so the fallback loop skips it
        // instead of resolving and re-spawning the same just-failed `ccusage` a second time.
        var alreadyTried: CcusageRunnerKind?

        // Fast path: re-use the runner that worked last time, skipping resolution (and its
        // `--version` probe spawns) entirely. On a non-timeout failure, drop the memo and fall back to
        // a full lazy resolution below (excluding this kind); a timeout short-circuits like the loop.
        if let cached = resolved.withLock({ $0 }) {
            do {
                switch try attempt(kind: cached.kind, program: cached.program, provider: provider, since: since, environment: environment) {
                case .success(let usage):
                    return .success(usage)
                case .failed(let error):
                    lastError = error
                    resolved.withLock { $0 = nil }
                    alreadyTried = cached.kind
                }
            } catch ProcessRunnerError.timedOut {
                AppLog.warn(LogTag.plugin("ccusage"), "\(cached.kind.label) timed out")
                return .failure(.timedOut)
            } catch {
                AppLog.warn(LogTag.plugin("ccusage"), "\(cached.kind.label) failed: \(LogRedaction.redactLogMessage(error.localizedDescription))")
                lastError = .failed(error.localizedDescription)
                resolved.withLock { $0 = nil }
                alreadyTried = cached.kind
            }
        }

        // Lazy resolution: resolve runners in priority order and stop at the first that actually runs
        // `ccusage`. Earlier this resolved ALL runner kinds up front (probing each absent one with a
        // `--version` spawn) and used only the first — so the lower-priority probes were pure waste.
        var resolvedAny = alreadyTried != nil

        for kind in CcusageRunnerKind.allCases where kind != alreadyTried {
            guard let program = resolveRunner(kind) else { continue }
            resolvedAny = true
            do {
                switch try attempt(kind: kind, program: program, provider: provider, since: since, environment: environment) {
                case .success(let usage):
                    resolved.withLock { $0 = (kind, program) }
                    return .success(usage)
                case .failed(let error):
                    lastError = error
                    continue
                }
            } catch ProcessRunnerError.timedOut {
                AppLog.warn(LogTag.plugin("ccusage"), "\(kind.label) timed out")
                return .failure(.timedOut)
            } catch {
                AppLog.warn(LogTag.plugin("ccusage"), "\(kind.label) failed: \(LogRedaction.redactLogMessage(error.localizedDescription))")
                lastError = .failed(error.localizedDescription)
                continue
            }
        }

        guard resolvedAny else {
            AppLog.warn(LogTag.plugin("ccusage"), "no package runner found")
            // Debug-only: the tried runner kinds plus the enriched PATH (which carries the user's
            // home), routed through `redactLogMessage` so the username never lands in the log.
            let tried = CcusageRunnerKind.allCases.map(\.label).joined(separator: ", ")
            AppLog.debug(LogTag.plugin("ccusage"), "tried [\(tried)]; PATH \(LogRedaction.redactLogMessage(enrichedPath()))")
            return .failure(.noRunner)
        }

        AppLog.warn(LogTag.plugin("ccusage"), "all package runners failed")
        return .failure(lastError)
    }

    /// Run `ccusage … daily` through one resolved runner. Returns `.success` with the parsed usage or
    /// `.failed` to fall through to the next runner; rethrows `ProcessRunnerError.timedOut` so the
    /// caller can stop trying fallbacks.
    private func attempt(
        kind: CcusageRunnerKind,
        program: String,
        provider: CcusageProvider,
        since: String,
        environment: [String: String]
    ) throws -> Attempt {
        // The args are secret-free; the resolved program path may carry the user's home, so the
        // path itself is Debug-only and routed through `redactLogMessage`.
        AppLog.info(LogTag.plugin("ccusage"), "launch \(kind.label) \(provider.rawValue) daily")
        AppLog.debug(LogTag.plugin("ccusage"), "resolved \(kind.label) \(LogRedaction.redactLogMessage(program))")

        let result = try processRunner.run(
            executable: program,
            arguments: Self.runnerArgs(kind: kind, provider: provider, since: since),
            environment: environment,
            timeout: Self.timeout
        )
        guard result.succeeded else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.warn(LogTag.plugin("ccusage"), "\(kind.label) failed: \(LogRedaction.redactLogMessage(stderr))")
            return .failed(.failed(stderr))
        }
        guard let usage = Self.parseOutput(result.stdout) else {
            AppLog.warn(LogTag.plugin("ccusage"), "\(kind.label) invalid output")
            return .failed(.invalidOutput)
        }
        return .success(usage)
    }

    // MARK: - Runner resolution

    /// Every available runner, in fallback priority order, paired with the resolved program path.
    func collectRunners() -> [(kind: CcusageRunnerKind, program: String)] {
        CcusageRunnerKind.allCases.compactMap { kind in
            resolveRunner(kind).map { (kind, $0) }
        }
    }

    /// First working program for `kind`: absolute candidates are checked on disk; a bare command
    /// name is probed with `--version` so PATH resolution (incl. version managers) applies.
    func resolveRunner(_ kind: CcusageRunnerKind) -> String? {
        for candidate in Self.runnerCandidates(kind, home: homeDirectory()) {
            if candidate.hasPrefix("/") {
                if isExecutable(candidate) { return candidate }
            } else if commandExists(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func runnerCandidates(_ kind: CcusageRunnerKind, home: URL) -> [String] {
        switch kind {
        case .bunx:
            return [
                home.appendingPathComponent(".bun/bin/bunx").path,
                "/opt/homebrew/bin/bunx",
                "/usr/local/bin/bunx",
                "bunx"
            ]
        case .pnpmDlx:
            return ["/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm", "pnpm"]
        case .yarnDlx:
            return ["/opt/homebrew/bin/yarn", "/usr/local/bin/yarn", "yarn"]
        case .npmExec:
            return ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "npm"]
        case .npx:
            return ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "npx"]
        }
    }

    /// Argument vector for `kind`, ending in the shared `ccusage <provider> daily …` invocation.
    static func runnerArgs(kind: CcusageRunnerKind, provider: CcusageProvider, since: String) -> [String] {
        let leading: [String]
        switch kind {
        case .bunx:
            leading = ["--silent", packageSpec]
        case .pnpmDlx:
            leading = ["-s", "dlx", packageSpec]
        case .yarnDlx:
            leading = ["dlx", "-q", packageSpec]
        case .npmExec:
            leading = ["exec", "--yes", "--package=\(packageSpec)", "--", binName]
        case .npx:
            leading = ["--yes", packageSpec]
        }
        return leading + [provider.rawValue, "daily", "--json", "--order", "desc", "--since", since]
    }

    private func commandExists(_ command: String) -> Bool {
        do {
            let result = try processRunner.run(
                executable: command,
                arguments: ["--version"],
                environment: enrichedPathEnvironment(),
                timeout: Self.probeTimeout
            )
            return result.succeeded
        } catch {
            return false
        }
    }

    // MARK: - Environment

    private func ccusageEnvironment(provider: CcusageProvider, homePath: String?) -> [String: String] {
        var env = enrichedPathEnvironment()
        if provider == .codex, let homePath, !homePath.isEmpty {
            env["CODEX_HOME"] = expandHome(homePath)
        }
        if provider == .claude, let homePath, !homePath.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = expandHome(homePath)
        }
        return env
    }

    private func enrichedPathEnvironment() -> [String: String] {
        ["PATH": enrichedPath()]
    }

    private func enrichedPath() -> String {
        Self.pathEntries(home: homeDirectory(), existingPath: ProcessInfo.processInfo.environment["PATH"])
            .joined(separator: ":")
    }

    /// PATH entries to prepend before probing/launching runners: Bun, nvm (current + default
    /// alias), `~/.local/bin`, Homebrew, then the inherited PATH. A GUI menu-bar app inherits a
    /// stripped PATH, so version-manager bins must be added explicitly. Mirrors the Tauri host.
    static func pathEntries(home: URL, existingPath: String?) -> [String] {
        var entries: [String] = [
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".nvm/current/bin").path
        ]
        if let nvmDefault = nvmDefaultBinPath(home: home) {
            entries.append(nvmDefault)
        }
        entries.append(home.appendingPathComponent(".local/bin").path)
        entries.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        if let existingPath, !existingPath.isEmpty {
            entries.append(contentsOf: existingPath.split(separator: ":").map(String.init))
        }

        var seen = Set<String>()
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Resolves nvm's default alias (`~/.nvm/alias/default`, e.g. `22.16.0`) to its node `bin`
    /// directory (`~/.nvm/versions/node/v22.16.0/bin`). The alias may name a concrete version or
    /// point at another alias (`node`, `stable`, a custom name), which we follow one level. Returns
    /// nil if it's absent/empty or an unresolvable meta-alias (e.g. `lts/*`).
    static func nvmDefaultBinPath(home: URL) -> String? {
        let aliasDir = home.appendingPathComponent(".nvm/alias")
        guard let version = resolveNvmAlias("default", aliasDir: aliasDir) else { return nil }
        let normalized = version.hasPrefix("v") ? version : "v\(version)"
        return home.appendingPathComponent(".nvm/versions/node/\(normalized)/bin").path
    }

    /// Reads `<aliasDir>/<name>` and returns a concrete version string, following one level of
    /// alias indirection. nil if the file is missing/empty or doesn't resolve to a version.
    private static func resolveNvmAlias(_ name: String, aliasDir: URL) -> String? {
        func read(_ alias: String) -> String? {
            guard let raw = try? String(contentsOfFile: aliasDir.appendingPathComponent(alias).path, encoding: .utf8)
            else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        func isVersion(_ value: String) -> Bool {
            value.hasPrefix("v") || (value.first?.isNumber ?? false)
        }

        guard let value = read(name) else { return nil }
        if isVersion(value) { return value }
        // `value` is another alias (e.g. `default` -> `node`): follow it one level.
        guard let nested = read(value), isVersion(nested) else { return nil }
        return nested
    }

    static func parseOutput(_ stdout: String) -> CcusageDailyUsage? {
        guard let jsonText = extractLastJSONValue(stdout),
              let data = jsonText.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }

        let dailyRaw: [Any]
        if let array = raw as? [Any] {
            dailyRaw = array
        } else if let object = raw as? [String: Any],
                  let daily = object["daily"] as? [Any] {
            dailyRaw = daily
        } else {
            return nil
        }

        let days = dailyRaw.compactMap { entry -> CcusageDay? in
            guard let object = entry as? [String: Any],
                  let date = object["date"] as? String
            else {
                return nil
            }
            let totalTokens = readInt(object["totalTokens"]) ?? 0
            let costUSD = readDouble(object["totalCost"]) ?? readDouble(object["costUSD"])
            return CcusageDay(date: date, totalTokens: totalTokens, costUSD: costUSD)
        }

        return CcusageDailyUsage(daily: days)
    }

    static func extractLastJSONValue(_ stdout: String) -> String? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
            return trimmed
        }

        let scalars = Array(trimmed)
        for index in scalars.indices.reversed() {
            guard scalars[index] == "{" || scalars[index] == "[" else { continue }
            let candidate = String(scalars[index...])
            if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) ) != nil {
                return candidate
            }
        }
        return nil
    }

    private static func readInt(_ value: Any?) -> Int? {
        ProviderParse.number(value).map { Int($0) }
    }

    private static func readDouble(_ value: Any?) -> Double? {
        ProviderParse.number(value)
    }
}
