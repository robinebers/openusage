import Foundation

/// Deletes the autostart LaunchAgent left behind by the legacy Tauri edition (issues #607/#874).
///
/// `tauri-plugin-autostart` (edition ≤ 0.6.28) wrote `~/Library/LaunchAgents/OpenUsage.plist` with
/// `RunAtLoad = true`, pointing at the app binary by absolute path. Updating in place never removed
/// it, and on a case-insensitive volume (the APFS default) its Tauri-era program path
/// (`…/Contents/MacOS/openusage`, lowercase binary name) resolves to this edition's binary. Two
/// consequences for upgraded machines:
/// - the agent launches the app at every login *in addition to* the `SMAppService` login item —
///   the double launch behind #874 (`disableRelaunchOnLogin()` is AppKit-level and cannot suppress
///   a launchd agent), and
/// - Login Items & Extensions attributes the agent to the signing team ("SUNSTORY LLC") instead of
///   the app (#607): a bare LaunchAgent has no app identity, so macOS labels it by the code
///   signature of the binary it points to.
///
/// The removal decision is pure and deliberately conservative: only an agent whose program resolves
/// *inside this app's own bundle* is deleted. Anything else — a hand-rolled agent pointing at
/// another location, some other tool's agent that happens to share the filename — is left alone
/// (and logged, so a stray survivor is visible in the log file). Runs on every launch: the common
/// case is a single file-existence probe, and re-running covers a user who reinstalls the legacy
/// edition and upgrades again.
///
/// Deliberately file-only — no `launchctl bootout`. With `RunAtLoad`, the process the agent spawned
/// IS the service process, and if the single-instance survivor is the agent-launched copy (it's
/// whichever copy won the startup race), booting out the label would SIGTERM this very process.
/// Deleting the plist is sufficient and self-safe: launchd loads agents from disk at login, so the
/// next login has nothing to load, and the Login Items entry disappears once the file is gone.
enum LegacyLaunchAgentCleanup {
    /// What the legacy plist declares, as far as the removal decision cares. `programPath` is the
    /// executable the agent launches: launchd's `Program` key when present, else the first
    /// `ProgramArguments` element (`tauri-plugin-autostart` wrote only the latter).
    struct Agent: Equatable {
        var programPath: String?
    }

    /// `tauri-plugin-autostart` named the plist after the app's product name.
    static var defaultAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/OpenUsage.plist")
    }

    /// Live entry point, called once per launch. Parameters exist for tests only.
    static func removeLeftoverAgent(
        agentURL: URL = defaultAgentURL,
        bundlePath: String = Bundle.main.bundlePath
    ) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: agentURL.path) else { return }

        let agent: Agent
        do {
            agent = try parse(plistData: Data(contentsOf: agentURL))
        } catch {
            AppLog.error(.lifecycle, "found \(agentURL.path) but couldn't read it: \(error.localizedDescription)")
            return
        }

        guard shouldRemove(programPath: agent.programPath, bundlePath: bundlePath) else {
            AppLog.info(.lifecycle, "leaving \(agentURL.path) alone — its program (\(agent.programPath ?? "unset")) is outside this app bundle")
            return
        }

        do {
            try fileManager.removeItem(at: agentURL)
            AppLog.info(.lifecycle, "removed legacy Tauri autostart agent \(agentURL.path) — it pointed into this app bundle and double-launched the app at login (#874)")
        } catch {
            AppLog.error(.lifecycle, "couldn't delete legacy autostart agent \(agentURL.path): \(error.localizedDescription) — will retry next launch")
        }
    }

    /// Pure decision: remove only when the agent's program lives inside our own `.app` bundle.
    /// The comparison is case-insensitive to mirror the APFS default — the whole reason the
    /// lowercase Tauri path still launches this edition's binary. Requiring a `.app` bundle path
    /// keeps unbundled runs (`swift run`, whose "bundle" is a build directory) from ever matching.
    static func shouldRemove(programPath: String?, bundlePath: String) -> Bool {
        guard let programPath else { return false }
        let bundle = (bundlePath as NSString).standardizingPath
        guard bundle.hasSuffix(".app") else { return false }
        let program = (programPath as NSString).standardizingPath
        return program.lowercased().hasPrefix(bundle.lowercased() + "/")
    }

    /// Extracts the launched executable from a launchd plist. Throws on non-plist data; unknown or
    /// missing keys yield a nil `programPath` (which `shouldRemove` treats as "leave it alone").
    static func parse(plistData: Data) throws -> Agent {
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        guard let dict = plist as? [String: Any] else {
            return Agent(programPath: nil)
        }
        let program = dict["Program"] as? String
            ?? (dict["ProgramArguments"] as? [String])?.first
        return Agent(programPath: program)
    }
}
