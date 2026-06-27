import Foundation

struct OpenRouterAuth: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case environment
        case configFile
    }

    var apiKey: String
    var source: Source
}

enum OpenRouterAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No OpenRouter API key. Set OPENROUTER_API_KEY or add it to ~/.config/openusage/openrouter.json."
        case .invalidKey:
            return "OpenRouter API key invalid. Check your key at openrouter.ai/keys."
        }
    }
}

/// Reads an OpenRouter API key the user has already placed on the machine. Unlike the CLI-backed
/// providers, OpenRouter has no companion app that stashes a credential in a known spot, so the key
/// comes from an environment variable or a small config file. The GUI app does not inherit the shell
/// environment, so the config file is the reliable path; the env var works when the app is launched
/// from a shell (e.g. during development) or seeded via `launchctl setenv`.
struct OpenRouterAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/openrouter.json",
        "~/.config/openrouter/key.json"
    ]
    /// Environment variables checked in order. `OPENROUTER_API_KEY` is the de-facto standard.
    static let environmentNames = ["OPENROUTER_API_KEY", "OPENROUTER_KEY"]

    var files: TextFileAccessing
    var environment: EnvironmentReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.environment = environment
    }

    /// Config file first, environment second — the order the provider docs document. The config file is
    /// the path a user edits to rotate or replace the key, so it must win over a stale `OPENROUTER_API_KEY`
    /// that an old `launchctl setenv` may have left in the app's environment.
    func loadAPIKey() -> OpenRouterAuth? {
        if let key = keyFromConfigFile() {
            return OpenRouterAuth(apiKey: key, source: .configFile)
        }
        if let key = keyFromEnvironment() {
            return OpenRouterAuth(apiKey: key, source: .environment)
        }
        return nil
    }

    private func keyFromEnvironment() -> String? {
        for name in Self.environmentNames {
            if let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func keyFromConfigFile() -> String? {
        for path in Self.configPaths {
            guard files.exists(path), let text = try? files.readText(path) else { continue }
            if let key = Self.keyFromConfigText(text) {
                return key
            }
        }
        return nil
    }

    /// Accept a JSON object with `apiKey` / `api_key` / `key`, or a plain-text file holding only the key.
    static func keyFromConfigText(_ text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for field in ["apiKey", "api_key", "key"] {
                if let value = (object[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        // Not JSON: treat as a plain-text key file, ignoring blank lines.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("{") ? nil : trimmed
    }
}
