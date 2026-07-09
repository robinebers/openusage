import XCTest
@testable import OpenUsage

final class CodexAuthCandidateTests: XCTestCase {
    func testDefaultAuthFilesPreserveAPIKeyThenOAuthFallbackOrder() {
        let store = CodexAuthStore(
            environment: FakeEnvironment(),
            files: FakeFiles([
                "~/.config/codex/auth.json": #"{"OPENAI_API_KEY":"sk-api-only"}"#,
                "~/.codex/auth.json": #"{"tokens":{"access_token":"oauth-token"}}"#
            ]),
            keychain: FakeKeychain()
        )

        let candidates = store.loadAuthCandidates()

        XCTAssertEqual(candidates.map(\.source), [
            .file(path: "~/.config/codex/auth.json"),
            .file(path: "~/.codex/auth.json")
        ])
        XCTAssertEqual(candidates.first?.auth.apiKey, "sk-api-only")
        XCTAssertFalse(candidates.first?.hasUsableAccessToken == true)
        XCTAssertEqual(candidates.last?.auth.tokens?.accessToken, "oauth-token")
        XCTAssertTrue(candidates.last?.hasUsableAccessToken == true)
    }
}

@MainActor
final class CodexAuthenticationFallbackTests: XCTestCase {
    func testAPIKeyOnlyFileFallsThroughToLaterOAuthFile() async {
        let http = successfulHTTPClient()
        let provider = makeProvider(
            files: FakeFiles([
                "~/.config/codex/auth.json": #"{"OPENAI_API_KEY":"sk-api-only"}"#,
                "~/.codex/auth.json": #"{"tokens":{"access_token":"oauth-file-token"}}"#
            ]),
            keychain: FakeKeychain(),
            http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(usageAuthorizations(in: http), ["Bearer oauth-file-token"])
    }

    func testAPIKeyOnlyFileStillReturnsExistingGuidanceWhenNoOAuthCandidateExists() async {
        let http = successfulHTTPClient()
        let provider = makeProvider(
            files: FakeFiles([
                "~/.config/codex/auth.json": #"{"OPENAI_API_KEY":"sk-api-only"}"#
            ]),
            keychain: FakeKeychain(),
            http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notAvailable)
        guard case .badge(_, let text, _, _) = snapshot.lines.first else {
            return XCTFail("expected the API-key guidance badge")
        }
        XCTAssertEqual(text, "Usage not available for API key.")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAPIKeyOnlyFileFallsThroughToKeychainOAuth() async {
        let http = successfulHTTPClient()
        let provider = makeProvider(
            files: FakeFiles([
                "~/.config/codex/auth.json": #"{"OPENAI_API_KEY":"sk-api-only"}"#
            ]),
            keychain: FakeKeychain(#"{"tokens":{"access_token":"keychain-oauth-token"}}"#),
            http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(usageAuthorizations(in: http), ["Bearer keychain-oauth-token"])
    }

    func testUsageUnauthorizedThenRefresh503PreservesHTTP5xxCategory() async {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.usageURL:
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            case CodexUsageClient.refreshURL:
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            default:
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let provider = makeProvider(
            files: FakeFiles([
                "~/.config/codex/auth.json":
                    #"{"tokens":{"access_token":"stale-token","refresh_token":"refresh-token"}}"#
            ]),
            keychain: FakeKeychain(),
            http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
        guard case .badge(_, let text, _, _) = snapshot.lines.first else {
            return XCTFail("expected the refresh failure badge")
        }
        XCTAssertEqual(text, "Usage request failed (HTTP 503). Try again later.")
        XCTAssertEqual(http.requests.map(\.url), [
            CodexUsageClient.usageURL,
            CodexUsageClient.refreshURL
        ])
    }

    private func makeProvider(
        files: FakeFiles,
        keychain: FakeKeychain,
        http: any HTTPClient
    ) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(),
                files: files,
                keychain: keychain
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled }
        )
    }

    private func successfulHTTPClient() -> RoutingHTTPClient {
        RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
    }

    private func usageAuthorizations(in http: RoutingHTTPClient) -> [String?] {
        http.requests
            .filter { $0.url == CodexUsageClient.usageURL }
            .map { $0.headers["Authorization"] }
    }
}
