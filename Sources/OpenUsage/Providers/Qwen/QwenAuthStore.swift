import Foundation

/// A captured Qwen Cloud console session: the browser cookies that authenticate the billing API
/// (the load-bearing one is `login_qwencloud_ticket`) plus the plan region.
struct QwenSession: Hashable, Sendable {
    var cookies: String
    var region: String
}

enum QwenAuthError: Error, LocalizedError, Equatable {
    case notSignedIn
    case saveFailed
    case deleteFailed
    case signInCancelled

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Qwen Cloud. Open Qwen in Customize to sign in, or save your browser cookies to ~/.config/openusage/qwen.json."
        case .saveFailed:
            return "Couldn't save the Qwen Cloud session."
        case .deleteFailed:
            return "Couldn't remove the saved Qwen Cloud session."
        case .signInCancelled:
            return "Qwen Cloud sign-in was closed before completing."
        }
    }
}

/// Reads the Qwen Cloud console session OpenUsage uses to call the token-plan billing API. Qwen's
/// API keys are inference-only — plan usage lives behind the web console's session cookies, so the
/// credential here is a cookie header captured by the in-app sign-in window (`QwenLoginController`)
/// or pasted by hand into a config file. The file is the source of truth either way, and a user can
/// always rotate it by editing the file or signing in again.
struct QwenAuthStore: Sendable {
    static let configPath = "~/.config/openusage/qwen.json"
    /// The token-plan region the billing calls are scoped to. Only the international (Singapore)
    /// edition is supported in v1; carried in the config so other regions can land without a schema
    /// change.
    static let defaultRegion = "ap-southeast-1"

    var files: TextFileAccessing

    init(files: TextFileAccessing = LocalTextFileAccessor()) {
        self.files = files
    }

    func loadSession() -> QwenSession? {
        guard files.exists(Self.configPath),
              let text = try? files.readText(Self.configPath) else { return nil }
        return Self.session(fromConfigText: text)
    }

    /// Persist a captured session (0600 via `LocalTextFileAccessor`). `source` records how the
    /// cookies arrived ("webView" or "manual") — diagnostic only, never drives behavior.
    func saveSession(cookies: String, region: String = QwenAuthStore.defaultRegion, source: String) throws {
        let trimmed = cookies.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QwenAuthError.saveFailed }
        let object: [String: Any] = [
            "cookies": trimmed,
            "region": region,
            "source": source,
            "capturedAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { throw QwenAuthError.saveFailed }
        do {
            try files.writeText(Self.configPath, text)
        } catch {
            AppLog.error(.auth, "save Qwen session to \(Self.configPath) failed: \(error.localizedDescription)")
            throw QwenAuthError.saveFailed
        }
    }

    /// Remove the saved session. A missing file is a no-op. The WebView's own cookie store is left
    /// intact on purpose: the next sign-in silently recaptures the still-live browser session.
    func deleteSession() throws {
        guard files.exists(Self.configPath) else { return }
        do {
            try files.remove(Self.configPath)
        } catch {
            AppLog.error(.auth, "delete Qwen session at \(Self.configPath) failed: \(error.localizedDescription)")
            throw QwenAuthError.deleteFailed
        }
    }

    /// Accept a JSON object with `cookies` (and optional `region`), or a plain-text file holding only
    /// the cookie header — so a user who copies the header from DevTools can paste it straight in.
    static func session(fromConfigText text: String) -> QwenSession? {
        if let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let cookies = (object["cookies"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cookies.isEmpty {
            let region = (object["region"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? defaultRegion
            return QwenSession(cookies: cookies, region: region)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("{") else { return nil }
        return QwenSession(cookies: trimmed, region: defaultRegion)
    }
}
