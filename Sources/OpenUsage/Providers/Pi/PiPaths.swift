import Foundation

/// Where pi stores its session logs on this machine. Resolution mirrors pi itself: an explicit
/// `PI_CODING_AGENT_SESSION_DIR` wins, else `PI_CODING_AGENT_DIR/sessions` (the config-dir override),
/// else the default `~/.pi/agent/sessions`. Pi writes one `*.jsonl` per session under a
/// per-working-directory subfolder, so the directory is scanned recursively.
enum PiPaths {
    static func sessionsDirectory(environment: EnvironmentReading, homeDirectory: URL) -> URL {
        if let override = environment.value(for: "PI_CODING_AGENT_SESSION_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: expandHome(override))
        }
        if let configDir = environment.value(for: "PI_CODING_AGENT_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: expandHome(configDir)).appendingPathComponent("sessions")
        }
        return homeDirectory.appendingPathComponent(".pi/agent/sessions")
    }
}
