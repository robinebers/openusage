import CryptoKit
import Foundation

/// A `Sendable` wrapper around `UserDefaults` for the delegated-refresh layer's persisted state. The
/// `Foundation` class is thread-safe but not marked `Sendable`, so it can't be a stored property of a
/// `Sendable` struct without this shim. The delegated-refresh coordinator genuinely crosses isolation
/// (its touch runs in a detached `Task`), so the wrapper is the minimal escape hatch.
struct SendableUserDefaults: @unchecked Sendable {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
}

/// A token-free, log-safe snapshot of "which credential is currently on disk", used to detect whether
/// an external `claude` re-login actually rotated the stored credentials. We compare fingerprints
/// before and after delegating a refresh to the `claude` CLI: an unchanged fingerprint means the CLI
/// touch did NOT rotate the token (so the attempt failed), a changed one means it did (success).
///
/// NEVER carries a token value. `tokenHash` is a SHA256 of `accessToken + ":" + expiresAt`, so it
/// changes when either the access token or its expiry rotates but can never be reversed to the token.
/// The file `mtime`/`size` are a cheap secondary signal for the file source (the keychain has no file,
/// so those stay nil for keychain-sourced credentials and the token hash carries the whole signal).
struct ClaudeCredentialFingerprint: Codable, Equatable, Sendable {
    var tokenHash: String?
    var fileMTimeMs: Int?
    var fileSize: Int?

    /// Build a fingerprint from the OAuth blob OpenUsage already holds (so this never triggers an extra
    /// Security.framework keychain prompt) plus optional file metadata for the file-backed source.
    static func make(
        oauth: ClaudeOAuth?,
        credentialsPath: String?,
        files: TextFileAccessing
    ) -> ClaudeCredentialFingerprint {
        ClaudeCredentialFingerprint(
            tokenHash: tokenHash(for: oauth),
            fileMTimeMs: nil,
            fileSize: nil
        ).withFileMetadata(path: credentialsPath)
    }

    /// SHA256 of `accessToken + ":" + (expiresAt ?? 0)`. Returns nil when there is no access token. The
    /// value is a hex digest — never the token itself — so it is safe to persist and (in principle) log.
    static func tokenHash(for oauth: ClaudeOAuth?) -> String? {
        guard let accessToken = oauth?.accessToken, !accessToken.isEmpty else { return nil }
        let expiresAt = oauth?.expiresAt ?? 0
        // Format the expiry without scientific notation / locale drift so the hash is stable.
        let material = "\(accessToken):\(Int64(expiresAt.rounded()))"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a copy with `fileMTimeMs`/`fileSize` filled from the credentials file at `path` (if any).
    /// Metadata is read via `FileManager` directly — only the real local accessor exposes a filesystem
    /// path, so test doubles simply leave these nil and rely on the token hash, which is the real signal.
    private func withFileMetadata(path: String?) -> ClaudeCredentialFingerprint {
        guard let path, !path.isEmpty else { return self }
        let expanded = (path as NSString).expandingTildeInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: expanded) else {
            return self
        }
        var copy = self
        if let modified = attributes[.modificationDate] as? Date {
            copy.fileMTimeMs = Int(modified.timeIntervalSince1970 * 1000)
        }
        if let size = attributes[.size] as? NSNumber {
            copy.fileSize = size.intValue
        }
        return copy
    }
}
