import Foundation

/// A user-supplied API key already on the machine — an environment variable or a small JSON/plain-text
/// config file — for providers with no companion CLI/app that stashes a credential (OpenRouter, Z.ai).
/// The full read / status / save / delete behavior lives here so each such provider is a thin wrapper
/// over its own config paths, env-var names, and error messages instead of a line-for-line copy.
///
/// A GUI app launched from Finder/Dock doesn't inherit the interactive shell environment, so
/// `ProcessEnvironmentReader` captures the login shell's environment at launch (see
/// `LoginShellEnvironment`) — an env var exported in a shell profile is honored even in a packaged
/// build; the config file remains the explicit path.
struct UserAPIKeyStore: Sendable {
    /// A storage failure the wrapper maps to its provider's own typed error, preserving provider-specific
    /// user-facing messages and error categories.
    enum Failure: Sendable {
        case missingKey
        case credentialStoreUnreadable
        case invalidCredentialData
        case saveFailed
        case deleteFailed
    }

    let configPaths: [String]
    let environmentNames: [String]
    var files: TextFileAccessing
    var environment: EnvironmentReading
    let makeError: @Sendable (Failure) -> Error

    /// Config file first, environment second: the config file is the path a user edits to rotate or
    /// replace the key, so it wins over a stale env value an old `launchctl setenv` may have left behind.
    func loadKey() throws -> String? {
        let resolution = resolveKey()
        if let key = resolution.effectiveKey { return key }
        if let failure = resolution.configFailure { throw makeError(failure) }
        return nil
    }

    /// Resolve the editor status and reveal value from the same source snapshot. This prevents a
    /// hand-edited config from changing precedence between separate status and reveal reads.
    func editorSnapshot() -> APIKeyEditorSnapshot {
        let resolution = resolveKey()
        let status: APIKeyStatus
        if resolution.configFailure != nil {
            status = .savedKeyError
        } else {
            switch (resolution.configKey != nil, resolution.environmentKey != nil) {
            case (true, true): status = .overrideActive
            case (true, false): status = .saved
            case (false, true): status = .fromEnvironment
            case (false, false): status = .notSet
            }
        }
        return APIKeyEditorSnapshot(
            status: status,
            revealableKey: resolution.configFailure == nil ? resolution.effectiveKey : nil
        )
    }

    /// Persist `key` to the primary config file (as JSON `{"apiKey":"…"}`), which wins over a stale env
    /// var — so this is also the "override" path. Empty input is rejected as `.missingKey`.
    func saveKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw makeError(.missingKey) }
        let data = try JSONSerialization.data(withJSONObject: ["apiKey": trimmed], options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw makeError(.saveFailed) }
        do {
            try files.writeText(configPaths[0], text)
        } catch {
            AppLog.error(.auth, "save API key to \(configPaths[0]) failed")
            throw makeError(.saveFailed)
        }
    }

    /// Remove the saved key from every config path (not just the primary), so clearing truly clears it —
    /// otherwise a key in an alternate path would resurface. A missing file is a no-op.
    func deleteKey() throws {
        var failed = false
        for path in configPaths {
            do {
                try files.remove(path)
            } catch {
                // Keep clearing the remaining paths: a failure at one source must not leave an
                // unrelated lower-priority saved key behind. Log only the configured source path.
                AppLog.error(.auth, "delete API key at \(path) failed")
                failed = true
            }
        }
        if failed { throw makeError(.deleteFailed) }
    }

    private func keyFromEnvironment() -> String? {
        for name in environmentNames {
            if let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func resolveKey() -> KeyResolution {
        let config = keyFromConfigFile()
        let environmentKey = keyFromEnvironment()
        return KeyResolution(
            configKey: config.key,
            environmentKey: environmentKey,
            configFailure: config.failure
        )
    }

    private func keyFromConfigFile() -> ConfigResolution {
        var firstFailure: Failure?
        for path in configPaths {
            let text: String?
            do {
                text = try files.readTextIfPresent(path)
            } catch {
                // Never log the underlying error or file contents here: a credential adapter's error
                // can include sensitive context. The configured path is enough to diagnose access.
                AppLog.error(.auth, "API key config unreadable: \(path)")
                if firstFailure == nil { firstFailure = .credentialStoreUnreadable }
                continue
            }
            guard let text else { continue }
            if let key = Self.keyFromConfigText(text) {
                return ConfigResolution(key: key, failure: firstFailure)
            }
            AppLog.error(.auth, "API key config malformed: \(path)")
            if firstFailure == nil { firstFailure = .invalidCredentialData }
        }
        return ConfigResolution(key: nil, failure: firstFailure)
    }

    /// Accept a JSON object with `apiKey` / `api_key` / `key`, or a plain-text file holding only the key.
    static func keyFromConfigText(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `JSONSerialization` accepts a UTF-8 BOM, but it is not part of Swift's whitespace set. Drop
        // it before deciding whether the file is structured, otherwise a BOM-prefixed JSON object
        // would be sent verbatim as a plaintext credential.
        if trimmed.first == "\u{FEFF}" {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }

        guard let first = trimmed.first else { return nil }
        guard ["{", "[", "\""].contains(first) else {
            // Plain-text keys have no format restriction. Values such as `true` or `123` are valid
            // raw credentials unless a structured delimiter signals JSON intent.
            return trimmed
        }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            guard let object = json as? [String: Any] else { return nil }
            for field in ["apiKey", "api_key", "key"] {
                if let value = (object[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        return nil
    }

    private struct ConfigResolution: Sendable {
        var key: String?
        var failure: Failure?
    }

    private struct KeyResolution: Sendable {
        var configKey: String?
        var environmentKey: String?
        var configFailure: Failure?

        var effectiveKey: String? { configKey ?? environmentKey }
    }
}
