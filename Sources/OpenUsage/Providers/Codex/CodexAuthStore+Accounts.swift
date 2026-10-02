import Foundation

extension CodexAuthStore {
    func scoped(_ candidate: CodexAuthState) -> CodexAuthState? {
        var candidate = candidate
        if let expectedIdentity {
            guard candidate.hasUsableAccessToken,
                  CodexAccountIdentity(auth: candidate.auth) == expectedIdentity else { return nil }
            candidate.auth.tokens?.accountID = expectedIdentity.accountID.nilIfEmpty
            if isWritable(candidate.source) { return candidate }
        } else if !isDiscovered(candidate.source) || isWritable(candidate.source),
                  CodexSwapAccount.discover(environment: environment, files: files,
            home: FileManager.default.homeDirectoryForCurrentUser).isEmpty {
            return candidate
        }
        // A first Finder launch can defer account assembly until shell discovery completes.
        // Its temporary default card must also stay read-only, even with incomplete identity data.
        // xswap snapshots can share a refresh token with a running CLI. Only Codex may rotate it.
        candidate.auth.tokens?.refreshToken = nil
        candidate.readOnly = true
        return candidate
    }

    /// Sibling homes and pi entries reach the plain card only through account discovery, which keeps
    /// them read-only unless the home was found to be independent (see `isWritable`).
    private func isDiscovered(_ source: CodexAuthState.Source) -> Bool {
        switch source {
        case .file(let path): additionalAuthHomes.contains { path == $0.trimmingTrailingSlashes + "/auth.json" }
        case .keychain: false
        case .pi: true
        }
    }

    /// Only an independent Codex home may have its token rotated by OpenUsage. xswap's main and saved
    /// homes, pi, and the Keychain belong to tools that manage their own credential lifecycle.
    func isWritable(_ source: CodexAuthState.Source) -> Bool {
        guard case .file(let path) = source else { return false }
        return writableAuthHomes.contains(CodexHomeScanner.canonicalHome((path as NSString).deletingLastPathComponent))
    }

    func isCurrent(_ candidate: CodexAuthState) async -> Bool {
        switch candidate.source {
        case .file(let path): loadAuth(at: path) == candidate
        case .keychain(let account): await loadOffMainActor { loadKeychainAuth(account: account) } == candidate
        case .pi(let source): loadPiAuth(source) == candidate
        }
    }
}
