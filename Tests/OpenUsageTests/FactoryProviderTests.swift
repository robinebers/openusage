import CryptoKit
import XCTest
@testable import OpenUsage

final class FactoryAuthCryptoTests: XCTestCase {
    func testRoundTripsEncryptedEnvelope() throws {
        let key = SymmetricKey(size: .bits256)
        let keyBase64 = key.withUnsafeBytes { Data($0).base64EncodedString() }
        let plaintext = #"{"access_token":"jwt","refresh_token":"refresh"}"#

        let envelope = try FactoryAuthCrypto.encrypt(plaintext: plaintext, keyBase64: keyBase64)
        let decrypted = try FactoryAuthCrypto.decrypt(envelope: envelope, keyBase64: keyBase64)

        XCTAssertEqual(decrypted, plaintext)
    }
}

final class FactoryAuthStoreTests: XCTestCase {
    func testParsesLegacyAuthJSON() {
        let store = FactoryAuthStore(files: FakeFiles([
            FactoryAuthStore.legacyAuthPaths[1]: """
            {
              "access_token": "access-token",
              "refresh_token": "refresh-token"
            }
            """
        ]))

        let state = store.loadAuthState()

        XCTAssertEqual(state?.auth.accessToken, "access-token")
        XCTAssertEqual(state?.auth.refreshToken, "refresh-token")
        if case .legacyFile(let path) = state?.source {
            XCTAssertEqual(path, FactoryAuthStore.legacyAuthPaths[1])
        } else {
            XCTFail("expected legacy file source")
        }
    }

    func testDetectsCredentialSourcesWithoutParsingNetwork() {
        let store = FactoryAuthStore(files: FakeFiles([
            FactoryAuthStore.authV2Path: "ignored",
            FactoryAuthStore.authV2KeyPath: "key"
        ]))

        XCTAssertTrue(store.hasAnyCredentialSource())
    }

    func testEncryptsAndReloadsV2Auth() throws {
        let key = SymmetricKey(size: .bits256)
        let keyBase64 = key.withUnsafeBytes { Data($0).base64EncodedString() }
        let envelope = try FactoryAuthCrypto.encrypt(
            plaintext: #"{"access_token":"access","refresh_token":"refresh"}"#,
            keyBase64: keyBase64
        )
        let store = FactoryAuthStore(files: FakeFiles([
            FactoryAuthStore.authV2Path: envelope,
            FactoryAuthStore.authV2KeyPath: keyBase64
        ]))

        let state = store.loadAuthState()

        XCTAssertEqual(state?.auth.accessToken, "access")
        XCTAssertEqual(state?.auth.refreshToken, "refresh")
    }
}

final class FactoryUsageMapperTests: XCTestCase {
    func testMapsUIStyleLimitsLegacyTokensAndPlan() throws {
        let usage: [String: Any] = [
            "plan": "standard",
            "startDate": 1_770_623_326_000,
            "endDate": 1_770_956_800_000,
            "standardUsage": [
                "fiveHour": ["usedPercent": 12, "endDate": 1_770_641_326_000],
                "weekly": ["usedRatio": 0.34, "endDate": 1_770_728_126_000],
                "monthly": ["usedPercent": 8, "endDate": 1_771_128_926_000]
            ],
            "extraUsage": ["remainingUsd": 42.5],
            "droidCore": ["enabled": true],
            "managedComputers": ["usedHours": 2, "includedHours": 10, "endDate": 1_771_178_526_000],
            "standard": ["orgTotalTokensUsed": 5_000_000, "totalAllowance": 20_000_000],
            "premium": ["orgTotalTokensUsed": 0, "totalAllowance": 0]
        ]

        let mapped = try FactoryUsageMapper.mapUsageResponse(usage: usage)

        XCTAssertEqual(mapped.plan, "Standard + Droid Core")
        XCTAssertEqual(progress(mapped.lines, "5-hour usage")?.used, 12)
        XCTAssertEqual(progress(mapped.lines, "Weekly usage")?.used, 34)
        XCTAssertEqual(progress(mapped.lines, "Monthly usage")?.used, 8)
        XCTAssertEqual(dollars(mapped.lines, "Extra Usage"), 42.5, accuracy: 0.0001)
        XCTAssertEqual(badge(mapped.lines, "Droid Core")?.text, "Enabled")
        XCTAssertEqual(progress(mapped.lines, "Managed Computers")?.used, 2)
        XCTAssertEqual(progress(mapped.lines, "Standard")?.limit, 20_000_000)
        XCTAssertNil(progress(mapped.lines, "Premium"))
    }

    func testInfersLegacyPlanFromAllowance() throws {
        let usage: [String: Any] = [
            "standard": ["orgTotalTokensUsed": 1, "totalAllowance": 200_000_000]
        ]

        let mapped = try FactoryUsageMapper.mapUsageResponse(usage: usage)

        XCTAssertEqual(mapped.plan, "Max")
    }

    func testThrowsWhenNoDisplayableMetricsExist() {
        XCTAssertThrowsError(try FactoryUsageMapper.mapUsageResponse(usage: [:])) { error in
            XCTAssertEqual(error as? FactoryUsageError, .usageUnavailable)
        }
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }

    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }

    private func badge(_ lines: [MetricLine], _ label: String) -> (text: String, colorHex: String?)? {
        guard case .badge(_, let text, let colorHex, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (text, colorHex)
    }
}

@MainActor
final class FactoryProviderTests: XCTestCase {
    func testRefreshMapsUsageAndPersistsRotatedCredentials() async throws {
        let now = OpenUsageISO8601.date(from: "2026-07-14T10:00:00.000Z")!
        let jwt = makeJWT(exp: now.addingTimeInterval(3600))
        let files = FakeFiles([
            FactoryAuthStore.legacyAuthPaths[1]: """
            {"access_token":"\(jwt)","refresh_token":"refresh-token"}
            """
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url.absoluteString.hasPrefix(FactoryUsageClient.workOSAuthURL) {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh"}"#.utf8)
                )
            }
            if request.url.absoluteString.hasPrefix(FactoryUsageClient.usageURL) {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-access")
                let body = """
                {"usage":{"plan":"Pro","standardUsage":{"fiveHour":{"usedPercent":5},"weekly":{"usedPercent":10}},"standard":{"orgTotalTokensUsed":0,"totalAllowance":20000000}}}
                """
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = FactoryProvider(
            authStore: FactoryAuthStore(
                files: files,
                now: { OpenUsageISO8601.date(from: "2026-07-14T09:00:00.000Z")! }
            ),
            usageClient: FactoryUsageClient(http: httpClient),
            now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(progress(snapshot.lines, "5-hour usage")?.used, 5)
        let saved = FactoryAuthStore.parseAuthPayload(files.files[FactoryAuthStore.legacyAuthPaths[1]] ?? "")
        XCTAssertEqual(saved?.accessToken, "new-access")
        XCTAssertEqual(saved?.refreshToken, "new-refresh")
    }

    func testReturnsNotLoggedInWhenNoAuthExists() async {
        let provider = FactoryProvider(authStore: FactoryAuthStore(files: FakeFiles()))

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }

    private func makeJWT(exp: Date) -> String {
        let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64URLEncodedString()
        let payloadObject: [String: Any] = ["exp": exp.timeIntervalSince1970, "sub": "user_123"]
        let payloadData = try! JSONSerialization.data(withJSONObject: payloadObject)
        let payload = payloadData.base64URLEncodedString()
        return "\(header).\(payload).signature"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class RecordingHTTPClient: HTTPClient, @unchecked Sendable {
    private let handler: (HTTPRequest) -> HTTPResponse

    init(handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        handler(request)
    }
}
