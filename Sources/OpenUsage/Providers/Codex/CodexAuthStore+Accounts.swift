import Foundation

extension CodexAuthStore {
    func scoped(_ candidate: CodexAuthState) -> CodexAuthState? {
        var candidate = candidate
        if let expectedIdentity {
            guard candidate.hasUsableAccessToken,
                  CodexAccountIdentity(auth: candidate.auth) == expectedIdentity else { return nil }
            candidate.auth.tokens?.accountID = expectedIdentity.accountID.nilIfEmpty
        } else if CodexSwapAccount.discover(environment: environment, files: files,
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

    func isCurrent(_ candidate: CodexAuthState) async -> Bool {
        switch candidate.source {
        case .file(let path): loadAuth(at: path) == candidate
        case .keychain: await loadOffMainActor { loadKeychainAuth() } == candidate
        }
    }
}
