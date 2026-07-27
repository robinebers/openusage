import XCTest
@testable import OpenUsage

/// Hand-rolled protobuf encoders build synthetic `gen_metadata.data` blobs so the decoder and scanner
/// can be tested without a real Antigravity SQLite database. Field numbers mirror the Rust reference
/// implementation (`tokenusage`'s `extract_antigravity_gen_event`), validated against real local data.
private func encodeVarint(_ value: UInt64) -> [UInt8] {
    var v = value
    var bytes: [UInt8] = []
    while true {
        var byte = UInt8(v & 0x7f)
        v >>= 7
        if v != 0 { byte |= 0x80 }
        bytes.append(byte)
        if v == 0 { break }
    }
    return bytes
}

private func encodeTag(_ fieldNumber: UInt32, _ wireType: UInt8) -> [UInt8] {
    encodeVarint(UInt64(fieldNumber) << 3 | UInt64(wireType))
}

private func encodeVarintField(_ fieldNumber: UInt32, _ value: UInt64) -> [UInt8] {
    encodeTag(fieldNumber, 0) + encodeVarint(value)
}

private func encodeBytesField(_ fieldNumber: UInt32, _ payload: [UInt8]) -> [UInt8] {
    encodeTag(fieldNumber, 2) + encodeVarint(UInt64(payload.count)) + payload
}

private func encodeStringField(_ fieldNumber: UInt32, _ value: String) -> [UInt8] {
    encodeBytesField(fieldNumber, Array(value.utf8))
}

/// Builds a full `gen_metadata.data`-shaped blob: top field 1 wraps a message with model (19),
/// usage (4: input=2, output=3, cacheRead=5), and timing (9 -> 4 -> 1 = unix seconds).
private func buildGenBlob(model: String?, input: UInt64, output: UInt64, cacheRead: UInt64, timestampSecs: UInt64?) -> [UInt8] {
    var usage: [UInt8] = []
    usage += encodeVarintField(2, input)
    usage += encodeVarintField(3, output)
    usage += encodeVarintField(5, cacheRead)

    var wrapper: [UInt8] = []
    if let model { wrapper += encodeStringField(19, model) }
    wrapper += encodeBytesField(4, usage)
    if let timestampSecs {
        let wallClock = encodeVarintField(1, timestampSecs)
        let timing = encodeBytesField(4, wallClock)
        wrapper += encodeBytesField(9, timing)
    }

    return encodeBytesField(1, wrapper)
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

final class AntigravityProtoDecoderTests: XCTestCase {
    func testDecodeVarintSingleByte() {
        XCTAssertEqual(decodeVarint([0x05], 0)?.0, 5)
    }

    func testDecodeVarintMultiByte() {
        // 300 = 0b100101100 -> low 7 bits 0101100 (0x2c) with continuation, then 0b10 (0x02)
        XCTAssertEqual(decodeVarint([0xac, 0x02], 0)?.0, 300)
    }

    func testDecodeVarintTruncatedReturnsNil() {
        XCTAssertNil(decodeVarint([0x80], 0))
    }

    func testDecodeVarintOverflowReturnsNil() {
        let overflowing = [UInt8](repeating: 0xff, count: 11)
        XCTAssertNil(decodeVarint(overflowing, 0))
    }

    func testParseProtoFieldsRoundTripsVarintAndBytes() {
        let bytes = encodeVarintField(1, 42) + encodeStringField(2, "hi")
        let fields = parseProtoFields(bytes)
        XCTAssertEqual(findProtoVarint(fields, 1), 42)
        XCTAssertEqual(findProtoBytes(fields, 2).flatMap { String(bytes: $0, encoding: .utf8) }, "hi")
    }

    func testParseProtoFieldsStopsOnTruncation() {
        var bytes = encodeVarintField(1, 42)
        bytes += encodeTag(2, 2) + encodeVarint(50) // length-delimited field claiming 50 bytes it doesn't have
        let fields = parseProtoFields(bytes)
        XCTAssertEqual(findProtoVarint(fields, 1), 42)
        XCTAssertNil(findProtoBytes(fields, 2))
    }

    func testExtractFullRecord() throws {
        let blob = buildGenBlob(model: "gemini-3.1-pro-low", input: 1000, output: 200, cacheRead: 50, timestampSecs: 1_800_000_000)
        let event = try XCTUnwrap(extractAntigravityGenEvent(blob))
        XCTAssertEqual(event.model, "gemini-3.1-pro-low")
        XCTAssertEqual(event.inputTokens, 1000)
        XCTAssertEqual(event.outputTokens, 200)
        XCTAssertEqual(event.cacheReadTokens, 50)
        XCTAssertEqual(event.timestampSecs, 1_800_000_000)
    }

    func testExtractZeroTokensReturnsNil() {
        let blob = buildGenBlob(model: "gemini-3.6-flash", input: 0, output: 0, cacheRead: 0, timestampSecs: 1_800_000_000)
        XCTAssertNil(extractAntigravityGenEvent(blob))
    }

    func testExtractMissingWrapperReturnsNil() {
        // Top-level field 2 instead of the expected field 1 — no wrapper to find.
        let blob = encodeVarintField(2, 1)
        XCTAssertNil(extractAntigravityGenEvent(blob))
    }

    func testExtractMissingModelDefaultsToFlash() throws {
        let blob = buildGenBlob(model: nil, input: 10, output: 5, cacheRead: 0, timestampSecs: 1_800_000_000)
        let event = try XCTUnwrap(extractAntigravityGenEvent(blob))
        XCTAssertEqual(event.model, "gemini-3.6-flash")
    }

    func testExtractGarbageBlobReturnsNil() {
        XCTAssertNil(extractAntigravityGenEvent([0xff, 0xff, 0xff]))
    }
}

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var failing: Set<String>

    init(data: [String: String] = [:], failing: Set<String> = []) {
        self.data = data
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        return data[path]
    }

    func execute(path: String, sql: String) throws {}
}

final class AntigravityDbUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-27T12:00:00.000Z")!

    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "gemini-3.6-flash": ModelRates(inputPerMillion: 1, outputPerMillion: 4, cacheWritePerMillion: 1, cacheReadPerMillion: 0.25)
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private func hexArrayJSON(_ blobs: [[UInt8]]) -> String {
        "[" + blobs.map { "\"\(hex($0))\"" }.joined(separator: ",") + "]"
    }

    private func scanner(paths: [String: String]) -> AntigravityDbUsageScanner {
        AntigravityDbUsageScanner(
            sqlite: FakeSQLite(data: paths),
            conversationsDirectory: { "/convos" }
        )
    }

    func testNoDatabasesReturnsNil() async {
        let scanner = AntigravityDbUsageScanner(
            sqlite: FakeSQLite(),
            conversationsDirectory: { "/nonexistent-\(UUID().uuidString)" }
        )
        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
    }

    func testAccumulatesTokensAndCostFromBlobs() async throws {
        let todayTs = UInt64(now.timeIntervalSince1970) - 3600
        let blob = buildGenBlob(model: "gemini-3.6-flash", input: 1_000_000, output: 500_000, cacheRead: 0, timestampSecs: todayTs)
        let json = hexArrayJSON([blob])

        // scan() discovers files via FileManager, not the fake — write real (throwaway) files under a
        // temp dir so directory discovery finds them, while the fake SQLite accessor answers the query.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("a.db").path
        FileManager.default.createFile(atPath: dbPath, contents: nil)

        let scanner = AntigravityDbUsageScanner(
            sqlite: FakeSQLite(data: [dbPath: json]),
            conversationsDirectory: { dir.path }
        )
        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 1_500_000)
        // $1/M input * 1M + $4/M output * 0.5M = $1 + $2 = $3
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 3.0, accuracy: 0.0001)
    }

    func testUnpricedModelIsTrackedAsUnknownNotZeroCost() async throws {
        let ts = UInt64(now.timeIntervalSince1970) - 3600
        let blob = buildGenBlob(model: "gemini-9-mystery", input: 100, output: 50, cacheRead: 0, timestampSecs: ts)
        let json = hexArrayJSON([blob])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("a.db").path
        FileManager.default.createFile(atPath: dbPath, contents: nil)

        let scanner = AntigravityDbUsageScanner(
            sqlite: FakeSQLite(data: [dbPath: json]),
            conversationsDirectory: { dir.path }
        )
        let result = await scanner.scan(now: now, pricing: pricing)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unknownModelsByDay.values.flatMap { $0 }.first, "gemini-9-mystery")
    }

    func testOutOfWindowEventsAreExcluded() async throws {
        let oldTs = UInt64(now.addingTimeInterval(-60 * 86400).timeIntervalSince1970)
        let blob = buildGenBlob(model: "gemini-3.6-flash", input: 100, output: 50, cacheRead: 0, timestampSecs: oldTs)
        let json = hexArrayJSON([blob])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("a.db").path
        FileManager.default.createFile(atPath: dbPath, contents: nil)

        let scanner = AntigravityDbUsageScanner(
            sqlite: FakeSQLite(data: [dbPath: json]),
            conversationsDirectory: { dir.path }
        )
        let scan = await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
    }
}
