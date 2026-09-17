import XCTest
@testable import OpenUsage

@MainActor
final class CodexSwapReviewRegressionTests: XCTestCase {
    func testPartialDefaultIdentityStaysVisibleBesideSwapWithoutBorrowingItsCredentials() async throws {
        for missingWorkspace in [true, false] {
            let suite = "CodexSwapPartial.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let claims = missingWorkspace ? #"{"email":"personal@example.com"}"# : "{}"
            let idToken = "header." + Data(claims.utf8).base64EncodedString() + ".signature"
            let partial = CodexAuth(tokens: CodexTokens(accessToken: "partial", refreshToken: "never-use",
                idToken: idToken, accountID: missingWorkspace ? nil : "workspace-a"))
            let personal = CodexAccountIdentity(accountID: "workspace-a", email: "personal@example.com")!
            let work = CodexAccountIdentity(accountID: "workspace-b", email: "work@example.com")!
            let environment = FakeEnvironment(["CODEX_HOME": "/test/main",
                "XSWAP_HOME": "/test/.local/share/codex-swap"])
            let files = FakeFiles([
                "/test/main/auth.json": String(decoding: try JSONEncoder().encode(partial), as: UTF8.self),
                "/test/personal/auth.json": CodexSwapAccountTests.credential(personal, token: "saved-personal"),
                "/test/work/auth.json": CodexSwapAccountTests.credential(work, token: "saved-work"),
                "/test/.local/share/codex-swap/accounts.json": #"""
                {"schemaVersion":1,"mainHome":"/test/main","accounts":[
                  {"number":1,"alias":"Personal","home":"/test/personal",
                   "identity":{"accountId":"workspace-a","email":"personal@example.com"}},
                  {"number":2,"alias":"Work","home":"/test/work",
                   "identity":{"accountId":"workspace-b","email":"work@example.com"}}
                ]}
                """#
            ])
            let observer = DefaultAccountObserver(environment: environment, files: files,
                keychain: FakeKeychain(), homeDirectory: { URL(fileURLWithPath: "/test") })
            let store = ProviderAccountsStore(defaults: defaults)
            let assembly = await ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])
            XCTAssertEqual(assembly.codexCards.count, 3)
            guard let card = assembly.codexCards.first(where: {
                missingWorkspace ? $0.identity.accountID.isEmpty : $0.identity.email == nil
            }) else { return XCTFail("The partial default login disappeared") }
            XCTAssertEqual(card.id, "codex")
            XCTAssertFalse(card.allowsUnattributedHistory)
            XCTAssertEqual(Set(assembly.codexCards.map(\.displayName)).count, 3)
            let repeated = await ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])
            XCTAssertEqual(assembly.codexCards, repeated.codexCards)
            let original = files.files
            let deferred = CodexAuthStore(environment: environment, files: files, keychain: FakeKeychain())
            let credential = try XCTUnwrap(deferred.loadAuthCandidates().first)
            XCTAssertTrue(credential.readOnly)
            XCTAssertNil(credential.auth.tokens?.refreshToken)
            for status in [200, 403] {
                let http = RoutingHTTPClient { request in
                    XCTAssertEqual(request.method, "GET")
                    XCTAssertEqual(request.headers["Authorization"], "Bearer partial")
                    XCTAssertEqual(request.headers["ChatGPT-Account-Id"], missingWorkspace ? nil : "workspace-a")
                    return HTTPResponse(statusCode: status, headers: [:], body: Data(
                        #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":17,"limit_window_seconds":18000}}}"#.utf8))
                }
                let auth = CodexAuthStore(environment: environment, files: files,
                    keychain: FakeKeychain(CodexSwapAccountTests.credential(personal, token: "keychain-personal")),
                    expectedIdentity: card.identity, additionalAuthHomes: ["/test/personal", "/test/work"])
                let provider = CodexProvider(provider: CodexProvider.makeProvider(id: card.id),
                    authStore: auth, usageClient: CodexUsageClient(http: http),
                    logUsageScanner: CodexLogUsageScanner(allowsUnattributedHistory: false),
                    allowsUnattributedHistory: false, pricing: { TestPricing.bundled })
                let snapshot = await provider.refresh()
                if status == 200 {
                    XCTAssertNil(snapshot.errorCategory)
                    guard case .progress(_, let used, _, _, _, _, _, _) = snapshot.line(label: "Session")
                    else { return XCTFail("The default login lost its live limits") }
                    XCTAssertEqual(used, 17)
                } else {
                    XCTAssertNotNil(snapshot.errorCategory, "A known workspace must not supply the unidentified workspace's limits")
                }
                XCTAssertEqual(files.files, original)
            }
        }
    }
}
