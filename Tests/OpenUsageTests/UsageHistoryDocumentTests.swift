import XCTest
@testable import OpenUsage

final class UsageHistoryDocumentTests: XCTestCase {
    func testRoundTripPreservesModelsVariantsAndUnknownNames() throws {
        let document = makeDocument(deviceID: "mac-a", updatedAt: Date(timeIntervalSince1970: 100))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(UsageHistoryDocument.self, from: encoder.encode(document))

        XCTAssertEqual(decoded, document)
        XCTAssertNoThrow(try decoded.validate())
    }

    func testRejectsUnsupportedSchemaInvalidValuesAndImpossibleDates() {
        var document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        document.schema = "openusage.history.v3"
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .unsupportedSchema)
        }

        document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        document.providers["claude"]?.series.daily[0].date = "2026-02-30"
        XCTAssertThrowsError(try document.validate())

        document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        document.providers["claude"]?.series.daily[0].costUSD = -.infinity
        XCTAssertThrowsError(try document.validate())
    }

    func testRejectsDuplicateDaysAndModels() {
        var document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        let day = document.providers["claude"]!.series.daily[0]
        document.providers["claude"]?.series.daily.append(day)
        XCTAssertThrowsError(try document.validate())

        document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        let model = document.providers["claude"]!.modelUsage!.daily[0].models[0]
        document.providers["claude"]?.modelUsage?.daily[0].models.append(model)
        XCTAssertThrowsError(try document.validate())
    }

    func testValidatesV2IdentityMetadataAtTheBoundary() {
        var document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        document.identities = ["claude": "account-opaque|org-opaque"]
        XCTAssertNoThrow(try document.validate())

        document.identities = ["missing-provider": "account-opaque"]
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .invalidIdentityProvider("missing-provider"))
        }

        document.identities = ["claude": "  "]
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .invalidIdentity("claude"))
        }

        document.identities = ["claude": "alice@example.com"]
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .invalidIdentity("claude"))
        }

        document.identities = [
            "claude": ProviderInstanceID.pathDerivedIdentityKey(forCanonicalHome: "/Users/alice/.claude")
        ]
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .invalidIdentity("claude"))
        }
    }

    func testV2RequiresIdentitiesForAccountAwareProvidersButNotMachineLocalProviders() {
        var document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        let history = document.providers["claude"]!
        document.identities = nil
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .missingIdentity("claude"))
        }

        document.providers = ["codex@abc12345": history]
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .missingIdentity("codex@abc12345"))
        }

        document.providers = ["grok": history]
        XCTAssertNoThrow(try document.validate())
    }

    func testRejectsDuplicateIdentityWithinOneProviderFamilyButAllowsCrossFamilyValues() {
        var document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        let history = document.providers["claude"]!
        document.providers["claude@abc12345"] = history
        document.identities = ["claude": "same-account", "claude@abc12345": "same-account"]
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .duplicateIdentity("claude"))
        }

        document.providers = ["claude": history, "codex": history]
        document.identities = ["claude": "same-bytes", "codex": "same-bytes"]
        XCTAssertNoThrow(try document.validate(), "provider family namespaces unrelated account ids")
    }

    func testLegacyV1StillDecodesWithoutIdentitiesAndRejectsV2RoutingMetadata() {
        var document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        document.schema = UsageHistoryDocument.legacySchemaV1
        document.identities = nil
        XCTAssertNoThrow(try document.validate())

        document.identities = ["claude": "opaque-account"]
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .unexpectedIdentities)
        }
    }

    func testNewestDocumentWinsForDuplicateMachine() {
        let old = makeDocument(deviceID: "same-mac", updatedAt: Date(timeIntervalSince1970: 100))
        let newest = makeDocument(deviceID: "same-mac", updatedAt: Date(timeIntervalSince1970: 200))
        let other = makeDocument(deviceID: "other-mac", updatedAt: Date(timeIntervalSince1970: 150))

        let result = UsageHistoryDocument.newestByDevice([old, other, newest])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.deviceID == "same-mac" }?.updatedAt, newest.updatedAt)
    }

    private func makeDocument(deviceID: String, updatedAt: Date) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: deviceID,
            deviceName: "Test Mac",
            updatedAt: updatedAt,
            providers: [
                "claude": ProviderUsageHistory(
                    series: DailyUsageSeries(daily: [
                        DailyUsageEntry(date: "2026-07-13", totalTokens: 100, costUSD: 1.25)
                    ]),
                    modelUsage: ModelUsageSeries(daily: [
                        DailyModelUsageEntry(date: "2026-07-13", models: [
                            ModelUsageEntry(
                                model: "claude-opus",
                                totalTokens: 100,
                                costUSD: 1.25,
                                variants: [
                                    ModelUsageVariant(model: "claude-opus-thinking", totalTokens: 100, costUSD: 1.25)
                                ]
                            )
                        ])
                    ]),
                    unknownModelsByDay: ["2026-07-13": ["future-model"]]
                )
            ],
            identities: ["claude": "account-opaque"]
        )
    }
}
