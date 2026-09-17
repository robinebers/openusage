import CryptoKit
import XCTest
@testable import OpenUsage

/// A live `GET /api/usage` response, trimmed to the fields OpenUsage reads.
private let usageJSON = #"""
{"activity":{"cost":"1.25000","period":{"type":"last_4_weeks","starting_at":"2026-08-03T00:00:00Z","ending_at":"2026-08-24T19:39:56Z"},"models":[]},
 "limits":{"session":{"usage":0.349,"models":[{"name":"minimax-m3","request_count":139}]},
           "weekly":{"usage":0.316,"models":[{"name":"minimax-m3","request_count":646}]}}}
"""#

private let accountJSON = #"{"ID":"527bb449","Email":"user@example.com","Name":"user","Plan":"pro"}"#

private func data(_ json: String) -> Data { Data(json.utf8) }

private func ok(_ json: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: data(json))
}

/// Answers per request path, so the required usage call and the best-effort account call can have
/// different outcomes — the case a single canned `FakeHTTPClient` response cannot express.
private final class RoutedHTTPClient: HTTPClient, @unchecked Sendable {
    private let responses: [String: HTTPResponse]

    init(_ responses: [String: HTTPResponse]) { self.responses = responses }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        responses[request.url.path] ?? HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }
}

/// Builds an unencrypted OpenSSH ed25519 private key in memory, so no key material is ever committed
/// to the repository (a hardcoded PEM is a real private key as far as any secret scanner is concerned,
/// throwaway or not). Mirrors the container OpenSSH documents in `PROTOCOL.key`:
///
///     "openssh-key-v1\0" | string cipher | string kdf | string kdfoptions | uint32 keycount
///                        | string publickey | string privatekeys
///
/// Generating it per run also makes the parser tests stronger than a fixture would: they prove a real
/// round-trip rather than that one frozen blob still parses.
private enum TestSigningKey {
    /// `declaredPublicKey` overrides the container's outer public key — the half sent in the
    /// `Authorization` header — without touching the private half, reproducing the damaged file that
    /// signs correctly but identifies the wrong account.
    static func make(declaredPublicKey: Data? = nil) -> (pem: String, publicKeyRaw: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let seed = privateKey.rawRepresentation
        let publicKeyRaw = privateKey.publicKey.rawRepresentation
        let publicKeyBlob = string("ssh-ed25519") + string(declaredPublicKey ?? publicKeyRaw)

        var privateSection = uint32(0x1234_5678) + uint32(0x1234_5678)  // matching checkints
        privateSection += string("ssh-ed25519")
        privateSection += string(publicKeyRaw)
        privateSection += string(seed + publicKeyRaw)                   // ed25519 private = seed || public
        privateSection += string("")                                    // comment
        // The "none" cipher still pads to an 8-byte block, with 1, 2, 3, … as the filler.
        var padding: UInt8 = 1
        while privateSection.count % 8 != 0 {
            privateSection.append(padding)
            padding += 1
        }

        var blob = Data("openssh-key-v1\0".utf8)
        blob += string("none") + string("none") + string("")            // cipher, kdf, kdfoptions
        blob += uint32(1)                                               // key count
        blob += string(publicKeyBlob)
        blob += string(privateSection)

        let body = blob.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(body)
        -----END OPENSSH PRIVATE KEY-----
        """
        return (pem, publicKeyRaw)
    }

    /// SSH wire format: a big-endian `uint32` length followed by the payload.
    private static func string(_ payload: Data) -> Data { uint32(UInt32(payload.count)) + payload }
    private static func string(_ text: String) -> Data { string(Data(text.utf8)) }

    private static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

private let testKey = TestSigningKey.make()
private let testPrivateKeyPEM = testKey.pem

// MARK: - Key parsing

final class OpenSSHEd25519KeyTests: XCTestCase {
    func testParsesUnencryptedEd25519Key() throws {
        let key = try XCTUnwrap(OpenSSHEd25519Key.parse(pem: testPrivateKeyPEM))

        XCTAssertEqual(key.seed.count, 32)
        // The public half is the SSH wire-format blob: the "ssh-ed25519" type string (4 + 11 bytes)
        // followed by the 32-byte raw key (4 + 32), and it must be the key that was written.
        let blob = try XCTUnwrap(Data(base64Encoded: key.publicKeyBase64))
        XCTAssertEqual(blob.count, 51)
        XCTAssertTrue(String(decoding: blob, as: UTF8.self).contains("ssh-ed25519"))
        XCTAssertEqual(Data(blob.suffix(32)), testKey.publicKeyRaw)
        // The seed round-trips too: it must derive the same public key.
        let derived = try Curve25519.Signing.PrivateKey(rawRepresentation: key.seed)
        XCTAssertEqual(derived.publicKey.rawRepresentation, testKey.publicKeyRaw)
    }

    /// Regression: the outer public key is what the `Authorization` header carries, while the signature
    /// comes from the seed. A file pairing an intact private key with a foreign public half used to parse
    /// fine, then get rejected by ollama.com as "not signed in" — a dead end the user cannot fix by
    /// signing in again.
    func testRejectsKeyWhoseDeclaredPublicHalfDoesNotMatchItsPrivateHalf() {
        let foreign = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let damaged = TestSigningKey.make(declaredPublicKey: foreign)

        XCTAssertNil(OpenSSHEd25519Key.parse(pem: damaged.pem))
    }

    func testRejectsMalformedAndTruncatedKeys() {
        let body = testPrivateKeyPEM
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        let truncated = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(String(body.prefix(body.count / 2)))
        -----END OPENSSH PRIVATE KEY-----
        """
        let cases = [
            "",
            "not a key at all",
            "-----BEGIN OPENSSH PRIVATE KEY-----\nZm9v\n-----END OPENSSH PRIVATE KEY-----",
            truncated
        ]

        for pem in cases {
            XCTAssertNil(OpenSSHEd25519Key.parse(pem: pem), pem.prefix(40).description)
        }
    }
}

// MARK: - Auth store

final class OllamaAuthStoreTests: XCTestCase {
    func testReturnsNilWhenOllamaIsNotInstalled() throws {
        let store = OllamaAuthStore(files: FakeFiles())
        XCTAssertNil(try store.loadSigningKey())
    }

    func testReadsTheKeyOllamaWrites() throws {
        let store = OllamaAuthStore(files: FakeFiles([OllamaAuthStore.keyPath: testPrivateKeyPEM]))
        XCTAssertNotNil(try store.loadSigningKey())
    }

    func testUnparseableKeyThrowsInsteadOfReadingAsLoggedOut() {
        let store = OllamaAuthStore(files: FakeFiles([OllamaAuthStore.keyPath: "garbage"]))
        XCTAssertThrowsError(try store.loadSigningKey()) { error in
            XCTAssertEqual(error as? OllamaAuthError, .invalidKey)
        }
    }
}

// MARK: - Request signing

final class OllamaRequestSignerTests: XCTestCase {
    func testSignsTheMethodAndTimestampedURIOllamaExpects() async throws {
        let key = try XCTUnwrap(OpenSSHEd25519Key.parse(pem: testPrivateKeyPEM))
        let http = FakeHTTPClient(response: ok(usageJSON))
        let client = OllamaUsageClient(http: http, now: { Date(timeIntervalSince1970: 1_700_000_000) })

        _ = try await client.fetchUsage(key: key)

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://ollama.com/api/usage?ts=1700000000")

        // The header is "<base64 public key>:<base64 signature>" over "<METHOD>,<request-uri>".
        let header = try XCTUnwrap(request.headers["Authorization"])
        let parts = header.split(separator: ":", maxSplits: 1).map(String.init)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], key.publicKeyBase64)

        let signature = try XCTUnwrap(Data(base64Encoded: parts[1]))
        let blob = try XCTUnwrap(Data(base64Encoded: key.publicKeyBase64))
        // The raw public key is the last 32 bytes of the SSH blob (type string + length + key).
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(blob.suffix(32)))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data("GET,/api/usage?ts=1700000000".utf8)))
    }

    func testAccountRequestIsAPost() async throws {
        let key = try XCTUnwrap(OpenSSHEd25519Key.parse(pem: testPrivateKeyPEM))
        let http = FakeHTTPClient(response: ok(accountJSON))
        let client = OllamaUsageClient(http: http, now: { Date(timeIntervalSince1970: 1_700_000_000) })

        _ = try await client.fetchAccount(key: key)

        XCTAssertEqual(http.requests.first?.method, "POST")
        XCTAssertEqual(http.requests.first?.url.absoluteString, "https://ollama.com/api/me?ts=1700000000")
    }
}

// MARK: - Mapping

final class OllamaUsageMapperTests: XCTestCase {
    func testMapsLiveResponseToSessionWeeklyAndSpend() throws {
        let mapped = try OllamaUsageMapper.map(usageBody: data(usageJSON), accountBody: data(accountJSON))

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(mapped.lines.count, 3)

        // `usage` arrives as a fraction of the plan allowance, so 0.349 is 34.9%, not 0.349%.
        guard case .progress(let label, let used, let limit, let format, let resetsAt, let periodMs, _) =
                mapped.lines[0] else {
            return XCTFail("expected a session meter, got \(mapped.lines[0])")
        }
        XCTAssertEqual(label, "Session")
        XCTAssertEqual(used, 34.9, accuracy: 0.0001)
        XCTAssertEqual(limit, 100)
        XCTAssertEqual(format, .percent)
        // Ollama publishes neither a reset instant nor the current window's start, so the meter carries
        // no countdown and no period — a period without a reset date renders as a static "Resets in 5h".
        XCTAssertNil(resetsAt)
        XCTAssertNil(periodMs)

        guard case .progress(let weeklyLabel, let weeklyUsed, _, _, _, let weeklyPeriod, _) =
                mapped.lines[1] else {
            return XCTFail("expected a weekly meter, got \(mapped.lines[1])")
        }
        XCTAssertEqual(weeklyLabel, "Weekly")
        XCTAssertEqual(weeklyUsed, 31.6, accuracy: 0.0001)
        XCTAssertNil(weeklyPeriod)

        // `cost` is a decimal string, not a number.
        guard case .values(let spendLabel, let values, _, _, _, _) = mapped.lines[2] else {
            return XCTFail("expected a spend row, got \(mapped.lines[2])")
        }
        XCTAssertEqual(spendLabel, "Last 4 Weeks")
        XCTAssertEqual(values.map(\.kind), [.dollars])
        XCTAssertEqual(values.first?.number, 1.25)
    }

    func testMetricLabelsMatchTheProvidersWidgetDescriptors() async throws {
        let mapped = try OllamaUsageMapper.map(usageBody: data(usageJSON), accountBody: nil)
        let labels = await MainActor.run { OllamaProvider().widgetDescriptors.map(\.metricLabel) }

        // This captured response predates the monthly meter and must still omit absent limits.
        XCTAssertEqual(mapped.lines.map(\.label), labels.filter { $0 != "Monthly" })
    }

    func testMissingLimitsIsALoudFailureRatherThanAnEmptyDashboard() {
        XCTAssertThrowsError(try OllamaUsageMapper.usageLines(data(#"{"activity":{"cost":"0"}}"#))) { error in
            XCTAssertEqual(error as? OllamaUsageError, .invalidResponse)
        }
        XCTAssertThrowsError(try OllamaUsageMapper.usageLines(data("not json"))) { error in
            XCTAssertEqual(error as? OllamaUsageError, .invalidResponse)
        }
    }

    func testAbsentMeterIsOmittedRatherThanShownAtZero() throws {
        let lines = try OllamaUsageMapper.usageLines(data(#"{"limits":{"weekly":{"usage":0.5}}}"#))

        XCTAssertEqual(lines.map(\.label), ["Weekly"])
    }

    func testEmptyLimitsReadAsNoUsageData() throws {
        XCTAssertEqual(try OllamaUsageMapper.usageLines(data(#"{"limits":{}}"#)), [.noUsageData])
    }

    func testPlanNameAcceptsBothCasingsAndIsTitleCased() {
        XCTAssertEqual(OllamaUsageMapper.planName(from: data(#"{"Plan":"pro"}"#)), "Pro")
        XCTAssertEqual(OllamaUsageMapper.planName(from: data(#"{"plan":"max"}"#)), "Max")
        XCTAssertNil(OllamaUsageMapper.planName(from: data(#"{"Plan":""}"#)))
        XCTAssertNil(OllamaUsageMapper.planName(from: data("not json")))
    }
}

// MARK: - Provider

@MainActor
final class OllamaProviderRefreshTests: XCTestCase {
    func testMissingKeyReportsNotLoggedInWithoutCallingTheNetwork() async {
        let http = FakeHTTPClient(response: ok(usageJSON))
        let provider = OllamaProvider(
            authStore: OllamaAuthStore(files: FakeFiles()),
            usageClient: OllamaUsageClient(http: http, now: { Date(timeIntervalSince1970: 0) })
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testUnauthorizedUsageReportsSignInRatherThanAnHTTPError() async {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let provider = makeProvider(http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(snapshot.lines.first?.label, MetricLine.errorBadgeLabel)
    }

    func testServerErrorSurfacesAsAnHTTPFailure() async {
        let provider = makeProvider(http: FakeHTTPClient(
            response: HTTPResponse(statusCode: 503, headers: [:], body: Data())
        ))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
    }

    /// The account call is best-effort: `FakeHTTPClient` answers every request with the usage body, so
    /// the plan can't be read — the meters must still map.
    func testMetersSurviveAnUnreadablePlanResponse() async {
        let provider = makeProvider(http: FakeHTTPClient(response: ok(usageJSON)))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Last 4 Weeks"])
    }

    /// Ollama is opt-in: the signing key exists from Ollama's first run, so probing it would auto-enable
    /// the provider for every local-models user and greet them with a Cloud sign-in warning. The probe
    /// must stay false even when a perfectly good key is on disk.
    func testProviderIsOptInEvenWithAUsableKeyOnDisk() async {
        let provider = makeProvider(http: FakeHTTPClient(response: ok(usageJSON)))

        let hasCredentials = await provider.hasLocalCredentials()

        XCTAssertFalse(hasCredentials)
    }

    /// Regression: a failing plan lookup used to be indistinguishable from an account that simply has
    /// no plan. The meters must still refresh, but the failure has to be visible.
    func testFailedPlanLookupWarnsAndKeepsTheMeters() async {
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: HTTPResponse(statusCode: 500, headers: [:], body: Data())
        ]))

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Last 4 Weeks"])
    }

    func testSuccessfulPlanLookupCarriesNoWarning() async {
        let provider = makeProvider(http: RoutedHTTPClient([
            OllamaUsageClient.usagePath: ok(usageJSON),
            OllamaUsageClient.accountPath: ok(accountJSON)
        ]))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNil(snapshot.warning)
    }

    /// The spend row counts charges beyond the plan, so $0.00 does not mean an idle period. Marking it
    /// as a usage period would give it the "No usage in this period" hover, which would be wrong for a
    /// subscriber who used Ollama heavily inside their allowance.
    func testSpendRowIsNotMarkedAsAUsagePeriod() {
        let descriptors = OllamaProvider().widgetDescriptors
        let spend = descriptors.first { $0.id == "ollama.last4Weeks" }

        XCTAssertEqual(spend?.sample.isUsagePeriod, false)
    }

    private func makeProvider(http: any HTTPClient) -> OllamaProvider {
        OllamaProvider(
            authStore: OllamaAuthStore(files: FakeFiles([OllamaAuthStore.keyPath: testPrivateKeyPEM])),
            usageClient: OllamaUsageClient(http: http, now: { Date(timeIntervalSince1970: 0) })
        )
    }
}
