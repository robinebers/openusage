import XCTest
@testable import OpenUsage

final class ClaudeCredentialBoundaryTests: XCTestCase {
    func testMissingCredentialSourcesAreProvenAbsent() throws {
        let store = makeClaudeBoundaryStore()

        XCTAssertTrue(try store.loadCredentialCandidates().isEmpty)
    }

    func testUnreadableCredentialFileThrowsCredentialStoreUnreadable() {
        let store = makeClaudeBoundaryStore(
            files: ClaudeBoundaryFiles(failsCredentialRead: true)
        )

        XCTAssertThrowsError(try store.loadCredentialCandidates()) { error in
            XCTAssertEqual(error as? ClaudeAuthError, .credentialStoreUnreadable)
        }
    }

    func testMalformedCredentialFileThrowsInvalidCredentialData() {
        let store = makeClaudeBoundaryStore(
            files: ClaudeBoundaryFiles(credentialText: "{ not-json")
        )

        XCTAssertThrowsError(try store.loadCredentialCandidates()) { error in
            XCTAssertEqual(error as? ClaudeAuthError, .invalidCredentialData)
        }
    }

    func testTokenlessCredentialFileThrowsInvalidCredentialData() {
        let store = makeClaudeBoundaryStore(
            files: ClaudeBoundaryFiles(credentialText: #"{"claudeAiOauth":{"accessToken":"   "}}"#)
        )

        XCTAssertThrowsError(try store.loadCredentialCandidates()) { error in
            XCTAssertEqual(error as? ClaudeAuthError, .invalidCredentialData)
        }
    }

    func testUnreadableKeychainThrowsCredentialStoreUnreadable() {
        let store = makeClaudeBoundaryStore(
            keychain: ClaudeBoundaryKeychain(failAllReads: true)
        )

        XCTAssertThrowsError(try store.loadCredentialCandidates()) { error in
            XCTAssertEqual(error as? ClaudeAuthError, .credentialStoreUnreadable)
        }
    }

    func testMalformedKeychainValueThrowsInvalidCredentialData() {
        let keychain = ClaudeBoundaryKeychain()
        let store = makeClaudeBoundaryStore(keychain: keychain)
        keychain.currentUserValues[store.keychainServiceCandidates()[0]] = "{ not-json"

        XCTAssertThrowsError(try store.loadCredentialCandidates()) { error in
            XCTAssertEqual(error as? ClaudeAuthError, .invalidCredentialData)
        }
    }

    func testBlankKeychainValueThrowsInvalidCredentialData() {
        let keychain = ClaudeBoundaryKeychain()
        let store = makeClaudeBoundaryStore(keychain: keychain)
        keychain.currentUserValues[store.keychainServiceCandidates()[0]] = "  \n"

        XCTAssertThrowsError(try store.loadCredentialCandidates()) { error in
            XCTAssertEqual(error as? ClaudeAuthError, .invalidCredentialData)
        }
    }

    func testValidFileWinsWhenKeychainIsUnreadable() throws {
        let store = makeClaudeBoundaryStore(
            files: ClaudeBoundaryFiles(credentialText: claudeCredentialJSON(token: "file-token")),
            keychain: ClaudeBoundaryKeychain(failAllReads: true)
        )

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["file-token"])
        XCTAssertEqual(candidates.map(\.source), [.file])
    }

    func testValidKeychainWinsWhenFileIsUnreadable() throws {
        let keychain = ClaudeBoundaryKeychain()
        let store = makeClaudeBoundaryStore(
            files: ClaudeBoundaryFiles(failsCredentialRead: true),
            keychain: keychain
        )
        let service = store.keychainServiceCandidates()[0]
        keychain.currentUserValues[service] = claudeCredentialJSON(token: "keychain-token")

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain-token"])
        XCTAssertEqual(candidates.map(\.source), [.keychainCurrentUser(service: service)])
    }

    func testLaterLegacyKeychainValueWinsAfterCurrentUserReadFailure() throws {
        let keychain = ClaudeBoundaryKeychain()
        let store = makeClaudeBoundaryStore(keychain: keychain)
        let service = store.keychainServiceCandidates()[0]
        keychain.failingCurrentUserServices.insert(service)
        keychain.legacyValues[service] = claudeCredentialJSON(token: "legacy-token")

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["legacy-token"])
        XCTAssertEqual(candidates.map(\.source), [.keychainLegacy(service: service)])
    }

    func testKeepsDistinctCurrentUserAndLegacyKeychainCandidatesInOrder() throws {
        let keychain = ClaudeBoundaryKeychain()
        let store = makeClaudeBoundaryStore(keychain: keychain)
        let service = store.keychainServiceCandidates()[0]
        keychain.currentUserValues[service] = claudeCredentialJSON(token: "stale-token")
        keychain.legacyValues[service] = claudeCredentialJSON(token: "fresh-token")

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["stale-token", "fresh-token"])
        XCTAssertEqual(candidates.map(\.source), [
            .keychainCurrentUser(service: service),
            .keychainLegacy(service: service)
        ])
    }

    func testKeepsDistinctHashedAndBaseServiceCandidatesInOrder() throws {
        let keychain = ClaudeBoundaryKeychain()
        let store = makeClaudeBoundaryStore(keychain: keychain)
        let services = store.keychainServiceCandidates()
        XCTAssertEqual(services.count, 2)
        keychain.currentUserValues[services[0]] = claudeCredentialJSON(token: "hashed-token")
        keychain.currentUserValues[services[1]] = claudeCredentialJSON(token: "base-token")

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["hashed-token", "base-token"])
        XCTAssertEqual(candidates.map(\.source), [
            .keychainCurrentUser(service: services[0]),
            .keychainCurrentUser(service: services[1])
        ])
    }

    func testDeduplicatesCredentialReturnedByBothKeychainLookups() throws {
        let keychain = ClaudeBoundaryKeychain()
        let store = makeClaudeBoundaryStore(keychain: keychain)
        let service = store.keychainServiceCandidates()[0]
        let credential = claudeCredentialJSON(token: "same-token")
        keychain.currentUserValues[service] = credential
        keychain.legacyValues[service] = credential

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["same-token"])
        XCTAssertEqual(candidates.map(\.source), [.keychainCurrentUser(service: service)])
    }

    func testEnvironmentTokenWinsWhenStoredSourcesAreMalformed() throws {
        let keychain = ClaudeBoundaryKeychain()
        let store = makeClaudeBoundaryStore(
            environment: FakeEnvironment([
                "CLAUDE_CONFIG_DIR": ClaudeBoundaryFiles.configDirectory,
                "CLAUDE_CODE_OAUTH_TOKEN": "environment-token"
            ]),
            files: ClaudeBoundaryFiles(credentialText: "{ not-json"),
            keychain: keychain
        )
        keychain.currentUserValues[store.keychainServiceCandidates()[0]] = "{ also-not-json"

        let candidates = try store.loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["environment-token"])
        XCTAssertEqual(candidates.map(\.source), [.environment])
    }

    @MainActor
    func testCredentialProbeAndRefreshDistinguishAbsentUnreadableAndMalformed() async {
        let absent = makeClaudeBoundaryProvider(files: ClaudeBoundaryFiles())
        let absentDetected = await absent.hasLocalCredentials()
        XCTAssertFalse(absentDetected)
        let absentSnapshot = await absent.refresh()
        XCTAssertEqual(absentSnapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(claudeBoundaryErrorText(absentSnapshot), ClaudeAuthError.notLoggedIn.localizedDescription)

        let unreadable = makeClaudeBoundaryProvider(
            files: ClaudeBoundaryFiles(failsCredentialRead: true)
        )
        let unreadableDetected = await unreadable.hasLocalCredentials()
        XCTAssertTrue(unreadableDetected)
        let unreadableSnapshot = await unreadable.refresh()
        XCTAssertEqual(unreadableSnapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(
            claudeBoundaryErrorText(unreadableSnapshot),
            ClaudeAuthError.credentialStoreUnreadable.localizedDescription
        )

        let malformed = makeClaudeBoundaryProvider(
            files: ClaudeBoundaryFiles(credentialText: "{ not-json")
        )
        let malformedDetected = await malformed.hasLocalCredentials()
        XCTAssertTrue(malformedDetected)
        let malformedSnapshot = await malformed.refresh()
        XCTAssertEqual(malformedSnapshot.errorCategory, .authInvalid)
        XCTAssertEqual(
            claudeBoundaryErrorText(malformedSnapshot),
            ClaudeAuthError.invalidCredentialData.localizedDescription
        )
    }

    @MainActor
    func testRefreshUsesValidFileDespiteUnreadableKeychain() async {
        let http = RoutingHTTPClient { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
            )
        }
        let provider = ClaudeProvider(
            authStore: makeClaudeBoundaryStore(
                files: ClaudeBoundaryFiles(credentialText: claudeCredentialJSON(token: "file-token")),
                keychain: ClaudeBoundaryKeychain(failAllReads: true)
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
    }

    @MainActor
    func testRefreshFallsBackFromStaleCurrentUserToValidLegacyKeychain() async {
        let keychain = ClaudeBoundaryKeychain()
        let store = makeClaudeBoundaryStore(keychain: keychain)
        let service = store.keychainServiceCandidates()[0]
        keychain.currentUserValues[service] = claudeCredentialJSON(token: "stale-token")
        keychain.legacyValues[service] = claudeCredentialJSON(token: "fresh-token")
        let http = RoutingHTTPClient { request in
            guard request.url.absoluteString.hasSuffix("/api/oauth/usage") else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            guard request.headers["Authorization"] == "Bearer fresh-token" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
            )
        }
        let provider = ClaudeProvider(
            authStore: store,
            usageClient: ClaudeUsageClient(httpClient: http),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertEqual(
            http.requests
                .filter { $0.url.absoluteString.hasSuffix("/api/oauth/usage") }
                .compactMap { $0.headers["Authorization"] },
            ["Bearer stale-token", "Bearer fresh-token"]
        )
    }
}

private func makeClaudeBoundaryStore(
    environment: EnvironmentReading = FakeEnvironment([
        "CLAUDE_CONFIG_DIR": ClaudeBoundaryFiles.configDirectory
    ]),
    files: TextFileAccessing = ClaudeBoundaryFiles(),
    keychain: KeychainAccessing = ClaudeBoundaryKeychain()
) -> ClaudeAuthStore {
    ClaudeAuthStore(
        environment: environment,
        files: files,
        keychain: keychain,
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
}

@MainActor
private func makeClaudeBoundaryProvider(files: TextFileAccessing) -> ClaudeProvider {
    ClaudeProvider(
        authStore: makeClaudeBoundaryStore(files: files),
        usageClient: ClaudeUsageClient(
            httpClient: FakeHTTPClient(
                response: HTTPResponse(statusCode: 500, headers: [:], body: Data())
            )
        ),
        logUsageScanner: ClaudeLogFixture.scanner(home: nil),
        pricing: { TestPricing.bundled }
    )
}

private func claudeCredentialJSON(token: String) -> String {
    #"{"claudeAiOauth":{"accessToken":"\#(token)","subscriptionType":"pro","scopes":["user:profile"]}}"#
}

private func claudeBoundaryErrorText(_ snapshot: ProviderSnapshot) -> String? {
    guard case .badge(_, let text, _, _) = snapshot.lines.first else { return nil }
    return text
}

private final class ClaudeBoundaryFiles: TextFileAccessing, @unchecked Sendable {
    static let configDirectory = "/tmp/openusage-claude-boundary"
    static let credentialPath = "\(configDirectory)/.credentials.json"

    let credentialText: String?
    let failsCredentialRead: Bool

    init(credentialText: String? = nil, failsCredentialRead: Bool = false) {
        self.credentialText = credentialText
        self.failsCredentialRead = failsCredentialRead
    }

    func exists(_ path: String) -> Bool {
        path == Self.credentialPath && (credentialText != nil || failsCredentialRead)
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        guard path == Self.credentialPath else { return nil }
        if failsCredentialRead { throw ClaudeBoundaryTestError.unreadable }
        return credentialText
    }

    func readText(_ path: String) throws -> String {
        if failsCredentialRead { throw ClaudeBoundaryTestError.unreadable }
        return credentialText ?? ""
    }

    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}
}

private final class ClaudeBoundaryKeychain: KeychainAccessing, @unchecked Sendable {
    var legacyValues: [String: String] = [:]
    var currentUserValues: [String: String] = [:]
    var failingLegacyServices: Set<String> = []
    var failingCurrentUserServices: Set<String> = []
    let failAllReads: Bool

    init(failAllReads: Bool = false) {
        self.failAllReads = failAllReads
    }

    func readGenericPassword(service: String) throws -> String? {
        if failAllReads || failingLegacyServices.contains(service) {
            throw ClaudeBoundaryTestError.unreadable
        }
        return legacyValues[service]
    }

    func writeGenericPassword(service: String, value: String) throws {
        legacyValues[service] = value
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        if failAllReads || failingCurrentUserServices.contains(service) {
            throw ClaudeBoundaryTestError.unreadable
        }
        return currentUserValues[service]
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        currentUserValues[service] = value
    }
}

private enum ClaudeBoundaryTestError: Error {
    case unreadable
}
