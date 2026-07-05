import XCTest
@testable import OpenUsage

final class GRPCWebCodecTests: XCTestCase {
    func testFrameWrapsMessageWithFlagAndBigEndianLength() {
        XCTAssertEqual(
            GRPCWebCodec.frame(Data([0x08, 0x01])),
            Data([0x00, 0x00, 0x00, 0x00, 0x02, 0x08, 0x01])
        )
        XCTAssertEqual(GRPCWebCodec.frame(Data()), Data([0x00, 0x00, 0x00, 0x00, 0x00]))
    }

    func testParsesUnarySuccess() throws {
        let message = Data([0x0A, 0x02, 0x08, 0x01])
        let body = GRPCWebCodec.frame(message) + GrokCreditsFixtures.okTrailerFrame

        let parsed = try GRPCWebCodec.parseUnary(body)

        XCTAssertEqual(parsed.status, 0)
        XCTAssertEqual(parsed.message, message)
    }

    func testParsesErrorStatusWithoutMessageFrame() throws {
        let parsed = try GRPCWebCodec.parseUnary(
            GrokCreditsFixtures.errorResponseBody(status: 13, message: "Missing request message")
        )

        XCTAssertEqual(parsed.status, 13)
        XCTAssertEqual(parsed.statusMessage, "Missing request message")
        XCTAssertNil(parsed.message)
    }

    func testTrailerNamesAreCaseInsensitive() throws {
        let parsed = try GRPCWebCodec.parseUnary(GrokCreditsFixtures.trailerFrame("Grpc-Status: 13\r\n"))
        XCTAssertEqual(parsed.status, 13)
    }

    func testRejectsTruncatedBody() {
        // A truncated success must never yield the message without its trailer — that would turn a
        // partial read of an error response into plausible data.
        let body = GRPCWebCodec.frame(Data([0x08, 0x01])) + GrokCreditsFixtures.okTrailerFrame
        for cut in [body.count - 1, body.count - 16, 3] {
            XCTAssertThrowsError(try GRPCWebCodec.parseUnary(body.prefix(cut))) { error in
                XCTAssertEqual(error as? GRPCWebCodecError, .truncatedResponse, "cut at \(cut)")
            }
        }
    }

    func testRejectsCompressedFrames() {
        var body = GRPCWebCodec.frame(Data([0x08, 0x01])) + GrokCreditsFixtures.okTrailerFrame
        body[body.startIndex] = 0x01 // compressed data frame

        XCTAssertThrowsError(try GRPCWebCodec.parseUnary(body)) { error in
            XCTAssertEqual(error as? GRPCWebCodecError, .compressedFrame)
        }
    }

    func testRejectsUnknownFrameFlag() {
        var body = GRPCWebCodec.frame(Data([0x08, 0x01])) + GrokCreditsFixtures.okTrailerFrame
        body[body.startIndex] = 0x40

        XCTAssertThrowsError(try GRPCWebCodec.parseUnary(body)) { error in
            XCTAssertEqual(error as? GRPCWebCodecError, .unknownFrameFlag(0x40))
        }
    }

    func testRejectsMissingTrailer() {
        XCTAssertThrowsError(try GRPCWebCodec.parseUnary(GRPCWebCodec.frame(Data([0x08, 0x01])))) { error in
            XCTAssertEqual(error as? GRPCWebCodecError, .missingTrailerStatus)
        }
        XCTAssertThrowsError(try GRPCWebCodec.parseUnary(Data())) { error in
            XCTAssertEqual(error as? GRPCWebCodecError, .missingTrailerStatus)
        }
    }

    func testRejectsMultipleTrailers() {
        let body = GrokCreditsFixtures.okTrailerFrame + GrokCreditsFixtures.okTrailerFrame
        XCTAssertThrowsError(try GRPCWebCodec.parseUnary(body)) { error in
            XCTAssertEqual(error as? GRPCWebCodecError, .multipleTrailers)
        }
    }

    func testRejectsSuccessWithWrongMessageCount() {
        XCTAssertThrowsError(try GRPCWebCodec.parseUnary(GrokCreditsFixtures.okTrailerFrame)) { error in
            XCTAssertEqual(error as? GRPCWebCodecError, .unexpectedMessageCount(0))
        }

        let doubled = GRPCWebCodec.frame(Data([0x08, 0x01])) + GRPCWebCodec.frame(Data([0x08, 0x02]))
            + GrokCreditsFixtures.okTrailerFrame
        XCTAssertThrowsError(try GRPCWebCodec.parseUnary(doubled)) { error in
            XCTAssertEqual(error as? GRPCWebCodecError, .unexpectedMessageCount(2))
        }
    }
}

final class ProtobufWireReaderTests: XCTestCase {
    func testReadsScalarAndNestedFields() throws {
        let nested = GrokCreditsFixtures.field(1, varint: 1_782_855_412) + GrokCreditsFixtures.field(2, varint: 140_114_000)
        let bytes = GrokCreditsFixtures.field(1, float: 99.0)
            + GrokCreditsFixtures.field(8, message: nested)
            + GrokCreditsFixtures.field(11, varint: 1)

        let message = try ProtobufMessage(bytes)

        XCTAssertEqual(message.float(1), 99.0)
        XCTAssertEqual(message.varint(11), 1)
        let period = try XCTUnwrap(message.message(8))
        XCTAssertEqual(period.varint(1), 1_782_855_412)
        XCTAssertEqual(period.varint(2), 140_114_000)
    }

    func testSkipsUnknownFieldsOfEveryWireType() throws {
        // Grok's schema drifts fast (field 13 appeared two days after the first capture): fields we
        // don't ask about — of every supported wire type — must never break the ones we do.
        let bytes = GrokCreditsFixtures.field(7, message: GrokCreditsFixtures.field(1, varint: 2))
            + GrokCreditsFixtures.field(99, fixed64: 0xDEAD_BEEF)
            + GrokCreditsFixtures.field(1, float: 42.5)
            + GrokCreditsFixtures.field(13, varint: 1)
            + GrokCreditsFixtures.field(12, message: Data())

        XCTAssertEqual(try ProtobufMessage(bytes).float(1), 42.5)
    }

    func testLastOccurrenceWins() throws {
        let bytes = GrokCreditsFixtures.field(1, varint: 1) + GrokCreditsFixtures.field(1, varint: 2)
        XCTAssertEqual(try ProtobufMessage(bytes).varint(1), 2)
    }

    func testAbsentFieldsReadAsNil() throws {
        let message = try ProtobufMessage(GrokCreditsFixtures.field(1, varint: 1))
        XCTAssertNil(message.varint(2))
        XCTAssertNil(message.float(1), "wire-type mismatch reads as absent, not as a garbage value")
        XCTAssertNil(try message.message(3))
    }

    func testThrowsOnTruncatedInput() {
        XCTAssertThrowsError(try ProtobufMessage(Data([0x08]))) { error in
            XCTAssertEqual(error as? ProtobufWireError, .truncated) // varint value missing
        }
        XCTAssertThrowsError(try ProtobufMessage(Data([0x08, 0x80]))) { error in
            XCTAssertEqual(error as? ProtobufWireError, .truncated) // varint continuation bit dangling
        }
        XCTAssertThrowsError(try ProtobufMessage(Data([0x0A, 0x05, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? ProtobufWireError, .truncated) // length-delimited longer than input
        }
        XCTAssertThrowsError(try ProtobufMessage(Data([0x0D, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? ProtobufWireError, .truncated) // fixed32 with 2 bytes
        }
    }

    func testThrowsOnVarintOverflow() {
        let bytes = Data([0x08] + Array(repeating: UInt8(0x80), count: 10) + [0x01])
        XCTAssertThrowsError(try ProtobufMessage(bytes)) { error in
            XCTAssertEqual(error as? ProtobufWireError, .varintOverflow)
        }
    }

    func testThrowsOnTenthVarintByteOverflowingPayloadBits() {
        // At the 10th byte only the lowest payload bit still fits in 64 bits. `<<` silently drops
        // the overflow, so nine 0x80s + 0x02 would decode as 0 — a corrupt varint accepted as a
        // small value (e.g. a network-provided timestamp collapsing to 1970) instead of an error.
        let bytes = Data([0x08] + Array(repeating: UInt8(0x80), count: 9) + [0x02])
        XCTAssertThrowsError(try ProtobufMessage(bytes)) { error in
            XCTAssertEqual(error as? ProtobufWireError, .varintOverflow)
        }
    }

    func testDecodesMaxUInt64Varint() throws {
        // The canonical UInt64.max encoding (nine 0xFF + 0x01) uses exactly the one payload bit the
        // 10th byte is allowed — the overflow guard must not reject it.
        let bytes = Data([0x08] + Array(repeating: UInt8(0xFF), count: 9) + [0x01])
        XCTAssertEqual(try ProtobufMessage(bytes).varint(1), UInt64.max)
    }

    func testThrowsOnGroupWireType() {
        XCTAssertThrowsError(try ProtobufMessage(Data([0x0B]))) { error in // field 1, wire type 3
            XCTAssertEqual(error as? ProtobufWireError, .unsupportedWireType(3))
        }
    }
}
