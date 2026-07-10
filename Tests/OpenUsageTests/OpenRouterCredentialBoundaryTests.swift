import XCTest
@testable import OpenUsage

final class OpenRouterCredentialBoundaryAuthStoreTests: XCTestCase {
    func testMissingConfigsAndBlankEnvironmentRemainAbsent() throws {
        let store = OpenRouterAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment([
                "OPENROUTER_API_KEY": "  ",
                "OPENROUTER_KEY": "\n"
            ])
        )

        XCTAssertNil(try store.loadAPIKey())
        XCTAssertEqual(store.editorSnapshot(), APIKeyEditorSnapshot(status: .notSet, revealableKey: nil))
    }

    func testUnreadableConfigThrowsCredentialAccessErrorAndMarksEditorStatus() {
        let store = OpenRouterAuthStore(
            files: OpenRouterUnreadableFiles(paths: [OpenRouterAuthStore.configPaths[0]]),
            environment: FakeEnvironment()
        )

        XCTAssertThrowsError(try store.loadAPIKey()) { error in
            XCTAssertEqual(error as? OpenRouterAuthError, .credentialStoreUnreadable)
        }
        XCTAssertEqual(store.editorSnapshot(), APIKeyEditorSnapshot(status: .savedKeyError, revealableKey: nil))
    }

    func testMalformedConfigThrowsAuthInvalidErrorAndMarksEditorStatus() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey": }"#]),
            environment: FakeEnvironment()
        )

        XCTAssertThrowsError(try store.loadAPIKey()) { error in
            XCTAssertEqual(error as? OpenRouterAuthError, .invalidCredentialData)
        }
        XCTAssertEqual(store.editorSnapshot(), APIKeyEditorSnapshot(status: .savedKeyError, revealableKey: nil))
    }

    func testStructuredJSONFragmentsAreNeverAcceptedAsPlaintextKeys() {
        for value in ["[", #"["key"]"#, #""key""#] {
            let store = OpenRouterAuthStore(
                files: FakeFiles([OpenRouterAuthStore.configPaths[0]: value]),
                environment: FakeEnvironment()
            )

            XCTAssertThrowsError(try store.loadAPIKey(), value) { error in
                XCTAssertEqual(error as? OpenRouterAuthError, .invalidCredentialData, value)
            }
        }
    }

    func testArbitraryNonStructuredPlaintextRemainsAValidKey() throws {
        for value in ["true", "123", "null"] {
            let store = OpenRouterAuthStore(
                files: FakeFiles([OpenRouterAuthStore.configPaths[0]: value]),
                environment: FakeEnvironment()
            )

            XCTAssertEqual(try store.loadAPIKey()?.apiKey, value)
        }
    }

    func testBOMPrefixedJSONObjectIsParsedInsteadOfSentAsPlaintext() throws {
        let store = OpenRouterAuthStore(
            files: FakeFiles([
                OpenRouterAuthStore.configPaths[0]: "\u{FEFF}{\"apiKey\":\"sk-or-bom\"}"
            ]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "sk-or-bom")
    }

    func testValidAlternateConfigWinsAfterMalformedPrimaryWithoutLyingInEditor() throws {
        let store = OpenRouterAuthStore(
            files: FakeFiles([
                OpenRouterAuthStore.configPaths[0]: #"{"apiKey": }"#,
                OpenRouterAuthStore.configPaths[1]: "sk-or-alternate"
            ]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(try store.loadAPIKey()?.apiKey, "sk-or-alternate")
        XCTAssertEqual(store.editorSnapshot(), APIKeyEditorSnapshot(status: .savedKeyError, revealableKey: nil))
    }

    func testEditorSnapshotKeepsStatusAndRevealValueFromOneResolution() {
        let files = OpenRouterSequencedFiles(
            path: OpenRouterAuthStore.configPaths[0],
            values: [#"{"apiKey":"sk-or-saved"}"#, nil]
        )
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        let snapshot = store.editorSnapshot()

        XCTAssertEqual(snapshot, APIKeyEditorSnapshot(status: .saved, revealableKey: "sk-or-saved"))
        XCTAssertEqual(files.readCount, 1, "one editor snapshot must not re-resolve status and key separately")
    }

    func testDeleteAttemptsEveryPathEvenWhenExistsProbeWouldMissTheFiles() {
        let files = OpenRouterDeleteFailureFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.deleteAPIKey()) { error in
            XCTAssertEqual(error as? OpenRouterAuthError, .deleteFailed)
        }
        XCTAssertEqual(
            files.removeCount,
            OpenRouterAuthStore.configPaths.count,
            "one inaccessible source must not prevent attempts to clear the remaining paths"
        )
    }

    func testPartialDeleteSnapshotNeverRetainsTheDeletedPrimaryKey() {
        let files = OpenRouterPartialDeleteFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertEqual(
            store.editorSnapshot(),
            APIKeyEditorSnapshot(status: .saved, revealableKey: "sk-or-primary")
        )
        XCTAssertThrowsError(try store.deleteAPIKey()) { error in
            XCTAssertEqual(error as? OpenRouterAuthError, .deleteFailed)
        }
        XCTAssertEqual(
            store.editorSnapshot(),
            APIKeyEditorSnapshot(status: .savedKeyError, revealableKey: nil)
        )
        XCTAssertEqual(files.removedPaths, OpenRouterAuthStore.configPaths)
    }
}

@MainActor
final class OpenRouterCredentialBoundaryProviderTests: XCTestCase {
    func testUnreadableConfigIsConservativelyDetectedAndSurfaced() async {
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(
                files: OpenRouterUnreadableFiles(paths: [OpenRouterAuthStore.configPaths[0]]),
                environment: FakeEnvironment()
            ),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("a terminal credential boundary error must not hit the network")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(openRouterErrorText(snapshot), OpenRouterAuthError.credentialStoreUnreadable.localizedDescription)
    }

    func testMalformedConfigIsConservativelyDetectedAndSurfaced() async {
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(
                files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey": }"#]),
                environment: FakeEnvironment()
            ),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("a terminal credential boundary error must not hit the network")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        )

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(openRouterErrorText(snapshot), OpenRouterAuthError.invalidCredentialData.localizedDescription)
    }

    func testEnvironmentFallbackKeepsIndependentEndpointSemantics() async {
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(
                files: OpenRouterUnreadableFiles(paths: [OpenRouterAuthStore.configPaths[0]]),
                environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env-fallback"])
            ),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                XCTAssertEqual(request.headers["Authorization"], "Bearer sk-or-env-fallback")
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
                }
                return openRouterBoundaryJSONResponse([
                    "data": ["is_free_tier": false, "usage_daily": 0.75]
                ])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Balance"))
        XCTAssertEqual(
            provider.apiKeyEditorSnapshot,
            APIKeyEditorSnapshot(status: .savedKeyError, revealableKey: nil)
        )
    }
}

private struct OpenRouterUnreadableFiles: TextFileAccessing {
    var paths: Set<String>

    func exists(_ path: String) -> Bool { paths.contains(path) }

    func readText(_ path: String) throws -> String {
        throw OpenRouterBoundaryTestError.unreadable
    }

    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

private enum OpenRouterBoundaryTestError: Error {
    case unreadable
}

private final class OpenRouterSequencedFiles: TextFileAccessing, @unchecked Sendable {
    let path: String
    private var values: [String?]
    private(set) var readCount = 0

    init(path: String, values: [String?]) {
        self.path = path
        self.values = values
    }

    func exists(_ path: String) -> Bool { path == self.path }
    func readText(_ path: String) throws -> String { try XCTUnwrap(readTextIfPresent(path)) }
    func readTextIfPresent(_ path: String) throws -> String? {
        guard path == self.path else { return nil }
        readCount += 1
        return values.isEmpty ? nil : values.removeFirst()
    }
    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

private final class OpenRouterDeleteFailureFiles: TextFileAccessing, @unchecked Sendable {
    private(set) var removeCount = 0

    func exists(_: String) -> Bool { false }
    func readText(_: String) throws -> String { throw OpenRouterBoundaryTestError.unreadable }
    func writeText(_: String, _: String) throws {}
    func remove(_: String) throws {
        removeCount += 1
        throw OpenRouterBoundaryTestError.unreadable
    }
}

private final class OpenRouterPartialDeleteFiles: TextFileAccessing, @unchecked Sendable {
    private var primary: String? = #"{"apiKey":"sk-or-primary"}"#
    private(set) var removedPaths: [String] = []

    func exists(_ path: String) -> Bool {
        path == OpenRouterAuthStore.configPaths[0] ? primary != nil : true
    }

    func readText(_ path: String) throws -> String {
        try XCTUnwrap(readTextIfPresent(path))
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        if path == OpenRouterAuthStore.configPaths[0] { return primary }
        throw OpenRouterBoundaryTestError.unreadable
    }

    func writeText(_: String, _: String) throws {}

    func remove(_ path: String) throws {
        removedPaths.append(path)
        if path == OpenRouterAuthStore.configPaths[0] {
            primary = nil
        } else {
            throw OpenRouterBoundaryTestError.unreadable
        }
    }
}

private func openRouterBoundaryJSONResponse(_ object: [String: Any]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return HTTPResponse(statusCode: 200, headers: [:], body: body)
}

private func openRouterErrorText(_ snapshot: ProviderSnapshot) -> String? {
    guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
    return text
}
