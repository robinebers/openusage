import XCTest
@testable import OpenUsage

final class DefaultAccountObserverTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/dev")

    private func makeObserver(
        environment: [String: String] = [:],
        files: [String: String] = [:],
        keychainValue: String? = nil
    ) -> DefaultAccountObserver {
        DefaultAccountObserver(
            environment: FakeEnvironment(environment),
            files: FakeFiles(files),
            keychain: FakeKeychain(keychainValue),
            homeDirectory: { [home] in home }
        )
    }

    private func claudeStateJSON(
        uuid: String? = "ACCT-UUID-1",
        email: String? = "dev@example.com",
        orgUuid: String? = nil,
        orgName: String? = nil
    ) -> String {
        var account: [String: String] = [:]
        if let uuid { account["accountUuid"] = uuid }
        if let email { account["emailAddress"] = email }
        if let orgUuid { account["organizationUuid"] = orgUuid }
        if let orgName { account["organizationName"] = orgName }
        let data = try! JSONSerialization.data(withJSONObject: ["oauthAccount": account])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Claude

    func testClaudeDefaultHomeResolvesFromUserLevelStateFile() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude.json": claudeStateJSON(),
        ])

        // The default `~/.claude` keeps its state at `~/.claude.json` — next to, not inside, the dir.
        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeIdentityIsOrgScoped() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude.json": claudeStateJSON(orgUuid: "ORG-9", orgName: "Sunstory"),
        ])

        // One human commonly has a personal Max org and a company Team org under the SAME account —
        // different usage pools, so the org id is part of the identity key.
        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1|org-9", label: "dev@example.com (Sunstory)", anchor: "/Users/dev/.claude")
        )
    }

    func testClaudeConfigDirOverrideReadsIdentityInsideTheDir() {
        let observer = makeObserver(
            environment: ["CLAUDE_CONFIG_DIR": "~/claude-work"],
            files: ["/Users/dev/claude-work/.claude.json": claudeStateJSON()]
        )

        XCTAssertEqual(
            observer.observeClaude(),
            .resolved(identityKey: "acct-uuid-1", label: "dev@example.com", anchor: "/Users/dev/claude-work")
        )
    }

    func testClaudeCommaListConfigDirIsUnresolved() {
        // `ClaudeAuthStore` treats the env value as ONE credential path; a scanner-style comma list
        // cannot be assigned a single account identity.
        let observer = makeObserver(
            environment: ["CLAUDE_CONFIG_DIR": "~/a,~/b"],
            files: ["/Users/dev/a/.claude.json": claudeStateJSON()]
        )

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "CLAUDE_CONFIG_DIR is a comma-separated list"))
    }

    func testClaudeCredentialsWithoutStateFileAreUnresolvedNotAbsent() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude/.credentials.json": "{}",
        ])

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "credentials present but no identity file"))
    }

    func testClaudeNoFootprintIsAbsent() {
        XCTAssertEqual(makeObserver().observeClaude(), .absent)
    }

    func testClaudeStateFileNamingNoAccountIsUnresolved() {
        let observer = makeObserver(files: [
            "/Users/dev/.claude.json": #"{"someOtherKey": true}"#,
        ])

        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "identity file present but names no account"))
    }

    // MARK: - Codex

    private func codexAuthJSON(accountID: String? = "codex-acct-1", idToken: String? = nil) -> String {
        var tokens: [String: String] = ["access_token": "at-1"]
        if let accountID { tokens["account_id"] = accountID }
        if let idToken { tokens["id_token"] = idToken }
        let data = try! JSONSerialization.data(withJSONObject: ["tokens": tokens])
        return String(data: data, encoding: .utf8)!
    }

    private func fakeJWT(payload: [String: Any]) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(["alg": "none"])).\(segment(payload)).sig"
    }

    func testCodexResolvesFromAccountIDInFirstDefaultHome() {
        let observer = makeObserver(files: [
            "/Users/dev/.codex/auth.json": codexAuthJSON(),
        ])

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "codex-acct-1", label: nil, anchor: "/Users/dev/.codex")
        )
    }

    func testCodexHomeOverrideWinsAndEmailComesFromIDToken() {
        let idToken = fakeJWT(payload: ["email": "dev@example.com"])
        let observer = makeObserver(
            environment: ["CODEX_HOME": "/opt/codex-alt"],
            files: ["/opt/codex-alt/auth.json": codexAuthJSON(idToken: idToken)]
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "codex-acct-1", label: "dev@example.com", anchor: "/opt/codex-alt")
        )
    }

    func testCodexFallsBackToChatGPTAccountClaim() {
        // The id_token's ChatGPT account claim is the value the CLI itself copies into `account_id`.
        let idToken = fakeJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "CLAIM-ACCT-2"],
        ])
        let observer = makeObserver(files: [
            "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: nil, idToken: idToken),
        ])

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "claim-acct-2", label: nil, anchor: "/Users/dev/.codex")
        )
    }

    func testCodexNamelessAuthFileIsUnresolvedNeverPathKeyed() {
        // The strict identity rule: an auth file that can't name its account NEVER becomes an
        // identity (no path-derived fallback) — it's reported, not guessed.
        let observer = makeObserver(files: [
            "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: nil),
        ])

        XCTAssertEqual(observer.observeCodex(), .unresolved(reason: "credentials present but no account identity"))
    }

    func testCodexNoFootprintIsAbsent() {
        XCTAssertEqual(makeObserver().observeCodex(), .absent)
    }

    func testCodexKeychainCredentialMakesTheFamilyUnresolved() {
        // The provider can fall back to the keychain credential when file auth fails, so while a
        // keychain item exists, the auth file's identity is not provably the producing account —
        // and we never read the keychain secret on the launch path to find out.
        let observer = makeObserver(
            files: ["/Users/dev/.codex/auth.json": codexAuthJSON()],
            keychainValue: #"{"tokens": {"access_token": "kc-at"}}"#
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .unresolved(reason: "keychain credential present or unverifiable — identity unresolved this launch")
        )
    }

    func testCodexUnverifiableKeychainProbeAlsoMakesTheFamilyUnresolved() {
        // A timed-out/failed probe (`nil`) must land on the same side as "item present": resolving
        // from the file while a keychain fallback might exist is the wrong-account stamp risk.
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.codex/auth.json": codexAuthJSON()]),
            keychain: ThrowingKeychain(),
            homeDirectory: { [home] in home }
        )

        XCTAssertEqual(
            observer.observeCodex(),
            .unresolved(reason: "keychain credential present or unverifiable — identity unresolved this launch")
        )
    }

    func testCodexXDGConfigHomeOrderMatchesAuthStore() {
        // `CodexAuthStore.authPaths()` probes `~/.config/codex` before `~/.codex`; the observer must
        // attribute the same home the provider actually loads credentials from.
        let observer = makeObserver(files: [
            "/Users/dev/.config/codex/auth.json": codexAuthJSON(accountID: "config-home-acct"),
            "/Users/dev/.codex/auth.json": codexAuthJSON(accountID: "legacy-home-acct"),
        ])

        XCTAssertEqual(
            observer.observeCodex(),
            .resolved(identityKey: "config-home-acct", label: nil, anchor: "/Users/dev/.config/codex")
        )
    }
}

private final class ThrowingKeychain: KeychainAccessing, @unchecked Sendable {
    struct Unavailable: Error {}
    func readGenericPassword(service: String) throws -> String? { throw Unavailable() }
    func writeGenericPassword(service: String, value: String) throws { throw Unavailable() }
}
