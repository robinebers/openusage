import XCTest
@testable import OpenUsage

@MainActor
final class CursorOptionalEndpointTests: XCTestCase {
    func testOptionalSchemaAndHTTPFailuresAreLoggedWithoutDiscardingPrimaryUsage() async throws {
        let accessToken = makeCursorJWT()
        let provider = makeProvider(accessToken: accessToken) { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return Self.primaryUsageResponse
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":42}}"#.utf8))
            case CursorUsageClient.creditsURL:
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            case CursorUsageClient.stripeURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("not-json".utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(logs.contains("optional plan response contained invalid plan metadata"), logs)
        XCTAssertTrue(logs.contains("optional credit-grants request returned HTTP 503"), logs)
        XCTAssertTrue(logs.contains("optional prepaid-balance response was invalid"), logs)
        XCTAssertFalse(logs.contains(accessToken), logs)
    }

    func testOptionalTransportAndSessionPreparationFailuresAreLogged() async throws {
        let provider = makeProvider(accessToken: makeCursorJWT(sub: nil)) { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return Self.primaryUsageResponse
            case CursorUsageClient.planURL, CursorUsageClient.creditsURL:
                throw URLError(.cannotConnectToHost)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(logs.contains("optional plan request failed"), logs)
        XCTAssertTrue(logs.contains("optional credit-grants request failed"), logs)
        XCTAssertTrue(logs.contains("optional prepaid-balance request could not be prepared from the current session"), logs)
    }

    /// The optional Grok Bot meter: failures log, ineligible shapes stay silent, and no case may
    /// discard the primary usage or emit a Grok Bot line.
    func testGrokBotFailuresAndIneligibleShapesHideTheMeterWithoutDiscardingPrimaryUsage() async throws {
        struct GrokBotCase {
            var name: String
            var response: HTTPResponse
            var expectedLog: String?  // nil → the invalid-usage warning must NOT appear
        }
        let invalidUsageLog = "Grok Bot usage response contained invalid usage metadata"
        let cases = [
            GrokBotCase(
                name: "HTTP failure",
                response: HTTPResponse(statusCode: 503, headers: [:], body: Data()),
                expectedLog: "optional Grok Bot usage request returned HTTP 503"
            ),
            GrokBotCase(
                name: "invalid usage metadata",
                response: HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"usagePercent":true,"hasNonZeroIncludedLimit":true}"#.utf8)
                ),
                expectedLog: "optional " + invalidUsageLog
            ),
            GrokBotCase(
                name: "ineligible account",
                response: HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"includedLimitZero":true}"#.utf8)
                ),
                expectedLog: nil
            ),
            GrokBotCase(
                name: "zero usage without included allowance",
                response: HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"usagePercent":0,"hasNonZeroIncludedLimit":false}"#.utf8)
                ),
                expectedLog: nil
            )
        ]

        for grokBotCase in cases {
            let response = grokBotCase.response
            let provider = makeProvider { request in
                switch request.url {
                case CursorUsageClient.usageURL:
                    return Self.primaryUsageResponse
                case CursorUsageClient.planURL:
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8))
                case CursorUsageClient.grokBotUsageURL:
                    return response
                default:
                    return HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            }

            let (snapshot, logs) = try await captureLogs { await provider.refresh() }

            XCTAssertNil(snapshot.errorCategory, grokBotCase.name)
            XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20, grokBotCase.name)
            XCTAssertNil(snapshot.lines.first { $0.label == "Grok Bot usage" }, grokBotCase.name)
            if let expectedLog = grokBotCase.expectedLog {
                XCTAssertTrue(logs.contains(expectedLog), "\(grokBotCase.name): \(logs)")
            } else {
                XCTAssertFalse(logs.contains(invalidUsageLog), "\(grokBotCase.name): \(logs)")
            }
        }
    }

    func testInvalidPlanMetadataStillEnablesRequestBasedFallback() async throws {
        let provider = makeProvider { request in
            if request.url.absoluteString.hasPrefix(CursorUsageClient.restUsageURL.absoluteString) {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"gpt-4":{"maxRequestUsage":500,"numRequests":100}}"#.utf8)
                )
            }
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true}"#.utf8))
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":42}}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(progress(snapshot.lines, "Requests")?.used, 100)
        XCTAssertEqual(progress(snapshot.lines, "Requests")?.limit, 500)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(logs.contains("optional plan response contained invalid plan metadata"), logs)
    }

    func testMissingPrepaidBalanceMetadataIsLoggedWithoutDiscardingPrimaryUsage() async throws {
        let provider = makeProvider { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return Self.primaryUsageResponse
            case CursorUsageClient.planURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"planInfo":{"planName":"pro"}}"#.utf8)
                )
            case CursorUsageClient.creditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            case CursorUsageClient.stripeURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"unexpected":true}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(logs.contains("optional prepaid-balance response contained invalid balance metadata"), logs)
    }

    func testBooleanCreditAndPrepaidMetadataIsLoggedWithoutBogusBalance() async throws {
        let provider = makeProvider { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return Self.primaryUsageResponse
            case CursorUsageClient.planURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"planInfo":{"planName":"pro"}}"#.utf8)
                )
            case CursorUsageClient.creditsURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"hasCreditGrants":true,"totalCents":true,"usedCents":0}"#.utf8)
                )
            case CursorUsageClient.stripeURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"customerBalance":true}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.lines.first { $0.label == "Credits" })
        XCTAssertTrue(logs.contains("optional credit-grants response contained invalid grant metadata"), logs)
        XCTAssertTrue(logs.contains("optional prepaid-balance response contained invalid balance metadata"), logs)
    }

    func testFailedGenericRequestFallbackIsLoggedBeforePrimaryMappingError() async throws {
        let provider = makeProvider { request in
            if request.url.absoluteString.hasPrefix(CursorUsageClient.restUsageURL.absoluteString) {
                return HTTPResponse(statusCode: 502, headers: [:], body: Data())
            }
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"enabled":true,"planUsage":{}}"#.utf8)
                )
            case CursorUsageClient.planURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"planInfo":{"planName":"pro"}}"#.utf8)
                )
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertTrue(logs.contains("optional request-based usage fallback failed"), logs)
    }

    private nonisolated static var primaryUsageResponse: HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(
                #"{"enabled":true,"billingCycleEnd":1772592000000,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}"#.utf8
            )
        )
    }

    private func makeProvider(
        accessToken: String = makeCursorJWT(),
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> CursorProvider {
        CursorProvider(
            authStore: CursorAuthStore(
                sqlite: KeyValueSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: RoutingHTTPClient(handler: handler)),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled }
        )
    }

    private func captureLogs(
        _ operation: () async -> ProviderSnapshot
    ) async throws -> (ProviderSnapshot, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.CursorOptional.\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.warn)
        defer {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshot = await operation()
        let logs = try String(contentsOf: directory.appendingPathComponent("OpenUsage.log"), encoding: .utf8)
        return (snapshot, logs)
    }

    private func progress(
        _ lines: [MetricLine],
        _ label: String
    ) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }
}

// makeCursorJWT and KeyValueSQLite live in TestSupport.swift.
