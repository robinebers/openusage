import Foundation

/// Typed failures for the Muse provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum MuseUsageError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// `auth.json` exists but could not be read — broken storage, not logout. `detail` carries
    /// the underlying cause for the log file; the user-facing description stays friendly.
    case credentialsUnreadable(detail: String)
    case apiKeyMissing
    case apiKeySaveFailed
    case apiKeyDeleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .apiKeyMissing
        case .saveFailed: self = .apiKeySaveFailed
        case .deleteFailed: self = .apiKeyDeleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Muse Code not detected. Log in with `muse login` or use Muse Code first."
        case .credentialsUnreadable:
            return "Couldn't read Muse Code's auth.json. Check its file permissions or run `muse login` again."
        case .apiKeyMissing:
            return "No Muse API key. Paste one in Settings or log in with `muse login`."
        case .apiKeySaveFailed:
            return "Couldn't save the Muse API key to ~/.config/openusage/muse.json."
        case .apiKeyDeleteFailed:
            return "Couldn't remove the saved Muse API key."
        }
    }
}

/// Reads the Muse Code credential already on the machine. Local-only — never the network.
/// `META_API_KEY` always wins (muse CLI behavior); otherwise the `auth.json` written by
/// `muse login` or `muse auth set --api-key-stdin`. Presence only: secrets are never returned
/// or logged. (The quota probe's bearer lives in `MuseQuotaClient`, which adds an explicit
/// saved-key override on top of the same env var plus the CLI keychain entry.)
struct MuseAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// The credential kind present on this machine, or `nil` when the user has not logged in.
    /// A present file that can't be read throws `credentialsUnreadable` so broken storage is never
    /// mistaken for logout; an absent file is the normal "not logged in" `nil`.
    func credential() throws -> MuseCredential? {
        if environment.value(for: "META_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil {
            return .apiKey
        }
        let path = MusePaths.authFilePath(environment: environment, homeDirectory: homeDirectory())
        let text: String?
        do {
            guard files.exists(path) else { return nil }
            text = try files.readText(path)
        } catch {
            throw MuseUsageError.credentialsUnreadable(detail: error.localizedDescription)
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .accountLogin
    }
}

/// Which Muse Code credential is present. Presence only — never the secret itself.
enum MuseCredential: Sendable, Equatable {
    /// `META_API_KEY` is exported in the environment.
    case apiKey
    /// A non-empty `auth.json` from `muse login` / `muse auth set`.
    case accountLogin
}
