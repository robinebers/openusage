import XCTest
@testable import OpenUsage

final class ZAICredentialBoundaryAuthStoreTests: XCTestCase {
    func testMissingConfigsAndBlankEnvironmentRemainAbsent() throws {
        let store = ZAIAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment([
                "ZAI_API_KEY": "  ",
                "GLM_API_KEY": "\n"
            ])
        )

        XCTAssertNil(try store.loadAPIKey())
        XCTAssertEqual(store.editorSnapshot(), APIKeyEditorSnapshot(status: .notSet, revealableKey: nil))
    }

    func testUnreadableConfigThrowsCredentialAccessErrorAndMarksEditorStatus() {
        let store = ZAIAuthStore(
            files: ZAIUnreadableFiles(paths: [ZAIAuthStore.configPaths[0]]),
            environment: FakeEnvironment()
        )

        XCTAssertThrowsError(try store.loadAPIKey()) { error in
            XCTAssertEqual(error as? ZAIAuthError, .credentialStoreUnreadable)
        }
        XCTAssertEqual(store.editorSnapshot(), APIKeyEditorSnapshot(status: .savedKeyError, revealableKey: nil))
    }

    func testMalformedConfigThrowsAuthInvalidErrorAndMarksEditorStatus() {
        let store = ZAIAuthStore(
            files: FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey": }"#]),
            environment: FakeEnvironment()
        )

        XCTAssertThrowsError(try store.loadAPIKey()) { error in
            XCTAssertEqual(error as? ZAIAuthError, .invalidCredentialData)
        }
        XCTAssertEqual(store.editorSnapshot(), APIKeyEditorSnapshot(status: .savedKeyError, revealableKey: nil))
    }

    func testEnvironmentFallbackWinsWithoutLyingAboutFailedSavedOverride() throws {
        let store = ZAIAuthStore(
            files: ZAIUnreadableFiles(paths: [ZAIAuthStore.configPaths[0]]),
            environment: FakeEnvironment(["ZAI_API_KEY": "zai-env-fallback"])
        )

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "zai-env-fallback")
        XCTAssertEqual(store.editorSnapshot(), APIKeyEditorSnapshot(status: .savedKeyError, revealableKey: nil))
    }
}

@MainActor
final class ZAICredentialBoundaryProviderTests: XCTestCase {
    func testUnreadableConfigIsConservativelyDetectedAndSurfaced() async {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(
                files: ZAIUnreadableFiles(paths: [ZAIAuthStore.configPaths[0]]),
                environment: FakeEnvironment()
            ),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("a terminal credential boundary error must not hit the network")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(zaiBoundaryErrorText(snapshot), ZAIAuthError.credentialStoreUnreadable.localizedDescription)
    }

    func testMalformedConfigIsConservativelyDetectedAndSurfaced() async {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(
                files: FakeFiles([ZAIAuthStore.configPaths[0]: #"{"apiKey": }"#]),
                environment: FakeEnvironment()
            ),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("a terminal credential boundary error must not hit the network")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(zaiBoundaryErrorText(snapshot), ZAIAuthError.invalidCredentialData.localizedDescription)
    }

    func testAlternateConfigFallbackPreservesQuotaAndBestEffortSubscriptionSemantics() async {
        let quota = #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":10}]}}"#
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(
                files: FakeFiles([
                    ZAIAuthStore.configPaths[0]: #"{"apiKey": }"#,
                    ZAIAuthStore.configPaths[1]: "zai-alternate"
                ]),
                environment: FakeEnvironment()
            ),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["Authorization"], "Bearer zai-alternate")
                if request.url == ZAIUsageClient.quotaURL {
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(quota.utf8))
                }
                return HTTPResponse(statusCode: 500, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(
            provider.apiKeyEditorSnapshot,
            APIKeyEditorSnapshot(status: .savedKeyError, revealableKey: nil)
        )
    }
}

private struct ZAIUnreadableFiles: TextFileAccessing {
    var paths: Set<String>

    func exists(_ path: String) -> Bool { paths.contains(path) }

    func readText(_ path: String) throws -> String {
        throw ZAIBoundaryTestError.unreadable
    }

    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

private enum ZAIBoundaryTestError: Error {
    case unreadable
}

private func zaiBoundaryErrorText(_ snapshot: ProviderSnapshot) -> String? {
    guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
    return text
}
