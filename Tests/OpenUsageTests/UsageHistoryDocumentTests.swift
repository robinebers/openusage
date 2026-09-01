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

    func testClaudeIdentitySupportsLegacyAndAccountCardSchemas() throws {
        var document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        document.identities = ["claude": "user|personal"]

        XCTAssertEqual(document.schema, "openusage.history.v1")
        XCTAssertNoThrow(try document.validate())
        XCTAssertEqual(try JSONDecoder().decode(
            UsageHistoryDocument.self,
            from: JSONEncoder().encode(document)
        ).identities, document.identities)

        document.schema = UsageHistoryDocument.accountSchema
        document.providers["claude@1234abcd"] = document.providers["claude"]
        document.identities?["claude@1234abcd"] = "user|work"

        XCTAssertNoThrow(try document.validate())

        document.schema = UsageHistoryDocument.currentSchema
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .invalidProvider("claude@1234abcd"))
        }
    }

    func testAccountSchemaAcceptsLegacyCodexIdentityWithoutRelaxingValidation() throws {
        var document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        document.schema = UsageHistoryDocument.accountSchema
        document.providers["codex"] = document.providers["claude"]
        // Earlier v2 writers included Codex ownership too. Identity namespaces are per provider.
        document.identities = ["claude": "shared-account-id", "codex": "shared-account-id"]
        let decoded = try JSONDecoder().decode(
            UsageHistoryDocument.self, from: JSONEncoder().encode(document)
        )
        XCTAssertNoThrow(try decoded.validate())

        for invalidIdentity in ["", "has space", "has\nnewline", "has/slash", "has\\backslash"] {
            document.identities?["codex"] = invalidIdentity
            XCTAssertThrowsError(try document.validate()) { error in
                XCTAssertEqual(error as? UsageHistoryDocumentError, .invalidIdentity("codex"))
            }
        }

        document.identities?["codex"] = "codex-account"
        document.providers.removeValue(forKey: "codex")
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .invalidIdentity("codex"))
        }
    }

    func testAccountSchemaRejectsMissingMismatchedAndDuplicateClaudeIdentities() {
        var document = makeDocument(deviceID: "mac-a", updatedAt: .now)
        document.schema = UsageHistoryDocument.accountSchema

        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .invalidIdentity("claude"))
        }

        document.identities = ["claude": "user|personal", "missing": "user|missing"]
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(error as? UsageHistoryDocumentError, .invalidIdentity("missing"))
        }

        document.providers["claude@1234abcd"] = document.providers["claude"]
        document.identities = ["claude": "User|Personal", "claude@1234abcd": "user|personal"]
        XCTAssertThrowsError(try document.validate()) { error in
            let identityError = error as? UsageHistoryDocumentError
            XCTAssertTrue(
                identityError == .duplicateIdentity("claude")
                    || identityError == .duplicateIdentity("claude@1234abcd")
            )
        }
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
            ]
        )
    }
}
