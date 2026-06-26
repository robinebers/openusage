import Foundation

/// Finds a running Codeium-derived language server (Antigravity's bundled `language_server`, or the
/// `agy` CLI) and returns the CSRF token + listening ports needed to call its local Connect-RPC service.
///
/// This is a native Swift port of the Tauri host's `ls.discover`: scan `ps` for the process, match it by
/// name + marker flags, pull `--csrf_token` / `--extension_server_port` from its argv, and read its
/// listening TCP ports via `lsof`. All work is blocking subprocess I/O, so call `discover` off the main
/// actor (e.g. via `loadOffMainActor`).
struct LanguageServerDiscovery: Sendable {
    struct Options: Sendable {
        /// Executable name to match (e.g. `language_server`, `agy`).
        var processName: String
        /// Lowercased marker values matched against `--app_data_dir` / `--ide_name` / `--override_ide_name`
        /// (exact), falling back to a `/marker/` path substring. Empty means "match any instance".
        var markers: [String]
        /// Flag whose value is the CSRF token (e.g. `--csrf_token`). Empty means the process has none.
        var csrfFlag: String
        /// Optional flag carrying an HTTP fallback port (e.g. `--extension_server_port`).
        var portFlag: String?
    }

    struct Result: Sendable {
        var pid: Int32
        var csrf: String
        var ports: [Int]
        var extensionPort: Int?
    }

    var processRunner: ProcessRunning = SystemProcessRunner()

    func discover(_ options: Options) -> Result? {
        guard let psOutput = try? processRunner.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            environment: [:],
            timeout: 5
        ), psOutput.succeeded else {
            AppLog.warn(.subprocess, "ls discover: ps failed for \(options.processName)")
            return nil
        }

        let candidates = Self.rankedCandidates(psOutput: psOutput.stdout, options: options)
        guard !candidates.isEmpty else {
            AppLog.info(.subprocess, "ls discover: \(options.processName) process not found")
            return nil
        }

        let lsofPath = ["/usr/sbin/lsof", "/usr/bin/lsof"].first { FileManager.default.fileExists(atPath: $0) }

        for candidate in candidates {
            let csrf: String
            if options.csrfFlag.trimmingCharacters(in: .whitespaces).isEmpty {
                csrf = ""
            } else if let value = Self.extractFlag(command: candidate.command, flag: options.csrfFlag) {
                csrf = value
            } else {
                continue
            }

            let extensionPort = options.portFlag
                .flatMap { Self.extractFlag(command: candidate.command, flag: $0) }
                .flatMap { Int($0) }

            var ports: [Int] = []
            if let lsofPath, let result = try? processRunner.run(
                executable: lsofPath,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(candidate.pid)],
                environment: [:],
                timeout: 5
            ), result.succeeded {
                ports = Self.parseListeningPorts(result.stdout)
            }

            if ports.isEmpty && extensionPort == nil {
                continue
            }

            AppLog.info(.subprocess, "ls discover: found \(options.processName) pid=\(candidate.pid) ports=\(ports)")
            return Result(pid: candidate.pid, csrf: csrf, ports: ports, extensionPort: extensionPort)
        }

        return nil
    }

    // MARK: - Pure helpers (port of the Rust host logic; unit-tested directly)

    /// Parse `ps -ax -o pid=,command=` output into the candidates that match the process + markers,
    /// sorted by marker rank (exact flag match before path-substring match).
    static func rankedCandidates(psOutput: String, options: Options) -> [(pid: Int32, command: String)] {
        let processNameLower = options.processName.lowercased()
        let markersLower = options.markers
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        var ranked: [(rank: Int, pid: Int32, command: String)] = []
        for rawLine in psOutput.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let spaceIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" })
            else { continue }
            let pidString = String(line[..<spaceIndex])
            let command = String(line[line.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidString),
                  commandMatchesProcess(command: command, processNameLower: processNameLower),
                  let rank = markerRank(command: command, markersLower: markersLower)
            else { continue }
            ranked.append((rank, pid, command))
        }

        return ranked
            .sorted { $0.rank < $1.rank }
            .map { (pid: $0.pid, command: $0.command) }
    }

    /// Extract the value of a CLI flag from a command string. Handles `--flag value` and `--flag=value`.
    static func extractFlag(command: String, flag: String) -> String? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let flagEq = flag + "="
        for (index, part) in parts.enumerated() {
            if part == flag {
                if index + 1 < parts.count { return parts[index + 1] }
            } else if part.hasPrefix(flagEq) {
                return String(part.dropFirst(flagEq.count))
            }
        }
        return nil
    }

    /// Marker match priority: exact `--ide_name` / `--override_ide_name` / `--app_data_dir` value (rank 0,
    /// prevents "antigravity" matching "antigravity-next"); else `/marker/` path substring (rank 1). No
    /// markers means match any instance (rank 0). Returns nil when nothing matches.
    static func markerRank(command: String, markersLower: [String]) -> Int? {
        if markersLower.isEmpty { return 0 }

        let ideName = extractFlag(command: command, flag: "--ide_name")?.lowercased()
        let overrideIdeName = extractFlag(command: command, flag: "--override_ide_name")?.lowercased()
        let appData = extractFlag(command: command, flag: "--app_data_dir")?.lowercased()
        if ideName != nil || overrideIdeName != nil || appData != nil {
            let matches = markersLower.contains { marker in
                ideName == marker || overrideIdeName == marker || appData == marker
            }
            return matches ? 0 : nil
        }

        let commandLower = command.lowercased()
        let matches = markersLower.contains { commandLower.contains("/\($0)/") }
        return matches ? 1 : nil
    }

    /// First argv token, honoring a quoted executable path.
    static func argv0(command: String) -> String {
        let trimmed = command.drop { $0 == " " || $0 == "\t" }
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        }
        let rest = trimmed.dropFirst()
        if let end = rest.firstIndex(of: quote) {
            return String(rest[..<end])
        }
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }

    static func commandMatchesProcess(command: String, processNameLower: String) -> Bool {
        guard !processNameLower.isEmpty else { return false }

        let exeName = (argv0(command: command) as NSString).lastPathComponent.lowercased()
        if exeName == processNameLower { return true }

        let commandLower = command.lowercased()
        if processNameLower.count >= 8 {
            return exeName.hasPrefix("\(processNameLower)_") || commandLower.contains(processNameLower)
        }
        return commandLower.hasSuffix("/\(processNameLower)")
            || commandLower.contains("/\(processNameLower) ")
            || commandLower.contains("/\(processNameLower)\t")
    }

    /// Parse listening port numbers from `lsof -nP -iTCP -sTCP:LISTEN` output (deduped, ascending).
    static func parseListeningPorts(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.contains("LISTEN") else { continue }
            // e.g. "... TCP 127.0.0.1:52168 (LISTEN)" — scan tokens in reverse for the address:port.
            for token in line.split(separator: " ").reversed() {
                if let colon = token.lastIndex(of: ":"),
                   let port = Int(token[token.index(after: colon)...]),
                   port > 0, port < 65_536 {
                    ports.insert(port)
                    break
                }
            }
        }
        return ports.sorted()
    }
}
