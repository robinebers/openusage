import XCTest
@testable import OpenUsage

final class CursorCSVBoundaryTests: XCTestCase {
    private let header = "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens"

    func testParserPreservesQuotedFieldsEscapesEmbeddedNewlinesAndCRLF() {
        let csv = "Date,Model,Note\r\n"
            + "2026-01-01T00:00:00Z,\"composer-1\",\"a, b \"\"quoted\"\" c\"\r\n"
            + "2026-01-02T00:00:00Z,composer-1,\"line one\r\nline two\"\r\n"
        var records: [[String: String]] = []

        let summary = CursorCSVParser.forEachRecord(in: csv) { records.append($0) }

        XCTAssertTrue(summary.isStructurallyComplete)
        XCTAssertEqual(summary.rejectedRecordCount, 0)
        XCTAssertEqual(records.count, 2)
        guard records.count == 2 else { return }
        XCTAssertEqual(records[0]["Note"], #"a, b "quoted" c"#)
        XCTAssertEqual(records[1]["Note"], "line one\r\nline two")
        XCTAssertEqual(records[1]["Model"], "composer-1")
    }

    func testParserParsesTrailingPartialRowWithoutNewline() {
        let csv = "Date,Model\n2026-01-01T00:00:00Z,composer-1"
        var records: [[String: String]] = []

        let summary = CursorCSVParser.forEachRecord(in: csv) { records.append($0) }

        XCTAssertTrue(summary.isStructurallyComplete)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["Date"], "2026-01-01T00:00:00Z")
        XCTAssertEqual(records[0]["Model"], "composer-1")
    }

    func testParserRejectsIllegalQuotePlacement() {
        let malformed = [
            "Date,Model\n2026-01-01T00:00:00Z,\"composer-1\"suffix",
            "Date,Model\n2026-01-01T00:00:00Z,com\"poser-1"
        ]

        for csv in malformed {
            let summary = CursorCSVParser.forEachRecord(in: csv) { _ in
                XCTFail("a structurally malformed record must not be emitted")
            }
            XCTAssertFalse(summary.isStructurallyComplete, csv)
        }
    }

    func testUsageCSVMapsColumnsToPricedRows() throws {
        let csv = """
        Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost
        2026-01-01T00:00:00Z,composer-1,No,0,0,0,1000000,Included
        2026-01-01T00:00:00Z,totally-unknown-model-xyz,No,0,100,0,0,Included
        ,skipped-no-date,No,0,0,0,0,Included
        """
        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)
        let rows = parsed.rows

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(parsed.rejectedRowCount, 1)
        XCTAssertEqual(rows[0].model, "composer-1")
        XCTAssertEqual(rows[0].tokens.output, 1_000_000)
        XCTAssertEqual(rows[0].imputedCostDollars!, 10.0, accuracy: 1e-9)
        XCTAssertEqual(rows[1].tokens.totalTokens, 100)
        XCTAssertNil(rows[1].imputedCostDollars)
    }

    func testUsageCSVDoesNotTreatAggregatedRowsAsSingleLongContextRequests() throws {
        var rates = ModelRates(
            inputPerMillion: 3,
            outputPerMillion: 15,
            cacheWritePerMillion: 3.75,
            cacheReadPerMillion: 0.3
        )
        rates.inputAbove200kPerMillion = 6
        rates.outputAbove200kPerMillion = 22.5
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["test-model": rates]),
            secondary: PricingCatalog()
        )
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,test-model,0,300000,0,100000
        """

        let row = try XCTUnwrap(CursorUsageCSV.parse(csv: csv, pricing: pricing).rows.first)

        XCTAssertEqual(row.imputedCostDollars!, 2.4, accuracy: 0.0001)
    }

    func testUsageCSVValidatesGroupedAndUngroupedIntegers() throws {
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,,,,
        2026-01-01T00:00:00Z,composer-1,0,"1,234",0,0
        2026-01-01T00:00:00Z,composer-1,0,",",0,0
        2026-01-01T00:00:00Z,composer-1,0,"1,2",0,0
        2026-01-01T00:00:00Z,composer-1,0,"1,,2",0,0
        2026-01-01T00:00:00Z,composer-1,0,"12,34",0,0
        2026-01-01T00:00:00Z,composer-1,0,-1,0,0
        2026-01-01T00:00:00Z,composer-1,0,1.5,0,0
        2026-01-01T00:00:00Z,composer-1,0,1e3,0,0
        2026-01-01T00:00:00Z,composer-1,0,9223372036854775808,0,0
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.map(\.tokens.totalTokens), [0, 1_234])
        XCTAssertEqual(parsed.rejectedRowCount, 8)
    }

    func testUsageCSVRejectsRowsWhoseTokenBucketsOverflow() throws {
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,\(Int.max),1,0,0
        2026-01-01T00:00:00Z,composer-1,0,100,0,0
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.map(\.tokens.totalTokens), [100])
        XCTAssertEqual(parsed.rejectedRowCount, 1)
    }

    func testUsageCSVRejectsAggregateOverflowWithoutDiscardingSafeRows() throws {
        let firstRowTokens = Int.max - 1
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,0,\(firstRowTokens),0,0
        2026-01-02T00:00:00Z,composer-1,0,2,0,0
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.map(\.tokens.totalTokens), [firstRowTokens])
        XCTAssertEqual(parsed.rejectedRowCount, 1)
    }

    func testUsageCSVAcceptsLargeNonOverflowingValues() throws {
        let large = Int.max / 2
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,0,\(large),0,1
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.first?.tokens.totalTokens, large + 1)
        XCTAssertEqual(parsed.rejectedRowCount, 0)
    }

    func testUsageCSVRejectsMismatchedRecordWidths() throws {
        let csv = """
        \(header)
        2026-01-01T00:00:00Z,composer-1,0,10,0,20
        2026-01-01T00:00:00Z,composer-1,0,10,0,20,
        2026-01-01T00:00:00Z,composer-1,0,10,0
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.map(\.tokens.totalTokens), [30])
        XCTAssertEqual(parsed.rejectedRowCount, 2)
    }

    func testUsageCSVAcceptsBOMQuotedHeadersAndOptionalColumns() throws {
        let csv = """
        "﻿Date","Model","Input (w/ Cache Write)","Input (w/o Cache Write)","Cache Read","Output Tokens",Cost
        2026-01-01T00:00:00Z,composer-1,,,,,Included
        """

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: TestPricing.bundled)

        XCTAssertEqual(parsed.rows.first?.tokens.totalTokens, 0)
        XCTAssertEqual(parsed.rejectedRowCount, 0)
    }

    func testUsageCSVRejectsMissingDuplicateAndStructurallyMalformedColumns() {
        let missingOutput = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read
        2026-01-01T00:00:00Z,composer-1,0,10,0
        """
        XCTAssertThrowsError(try CursorUsageCSV.parse(csv: missingOutput, pricing: TestPricing.bundled)) { error in
            XCTAssertEqual(error as? CursorUsageCSVError, .missingColumns(["Output Tokens"]))
        }

        let duplicateDate = """
        Date,Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
        2026-01-01T00:00:00Z,2026-01-01T00:00:00Z,composer-1,0,10,0,20
        """
        XCTAssertThrowsError(try CursorUsageCSV.parse(csv: duplicateDate, pricing: TestPricing.bundled)) { error in
            XCTAssertEqual(error as? CursorUsageCSVError, .malformedCSV)
        }

        let unterminated = """
        \(header)
        2026-01-01T00:00:00Z,"composer-1,0,10,0,20
        """
        XCTAssertThrowsError(try CursorUsageCSV.parse(csv: unterminated, pricing: TestPricing.bundled)) { error in
            XCTAssertEqual(error as? CursorUsageCSVError, .malformedCSV)
        }
    }
}
