import Foundation

extension CodexAuthStore {
    func scoped(_ candidate: CodexAuthState) -> CodexAuthState? {
        var candidate = candidate
        if let expectedIdentity {
            guard candidate.hasUsableAccessToken,
                  CodexAccountIdentity(auth: candidate.auth) == expectedIdentity else { return nil }
            candidate.auth.tokens?.accountID = expectedIdentity.accountID.nilIfEmpty
        } else if CodexSwapAccount.discover(
            environment: environment,
            files: files,
            home: FileManager.default.homeDirectoryForCurrentUser
        ).isEmpty {
            return candidate
        }

        let readOnly: Bool
        switch candidate.source {
        case .file(let path):
            let home = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .deletingLastPathComponent().standardizedFileURL.path
            readOnly = !writableAuthHomes.contains(home)
        case .keychain:
            readOnly = true
        case .pi:
            readOnly = true
        }
        if readOnly || expectedIdentity == nil {
            candidate.auth.tokens?.refreshToken = nil
            candidate.readOnly = true
        }
        return candidate
    }

    func isCurrent(_ candidate: CodexAuthState) async -> Bool {
        switch candidate.source {
        case .file(let path): loadAuth(at: path) == candidate
        case .keychain: await loadOffMainActor { loadKeychainAuth() } == candidate
        case .pi(let source): loadPiAuth(source) == candidate
        }
    }
}
