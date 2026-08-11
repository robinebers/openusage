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
        document.schema = "openusage.history.v2"
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
