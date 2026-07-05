import Foundation
@testable import OpenUsage

/// Builders and captured bytes for Grok's `GetGrokCreditsConfig` gRPC-web response, shared by the
/// decoder/mapper tests and the provider-level tests.
enum GrokCreditsFixtures {
    /// A real response body captured live from grok.com on 2026-07-05 (message frame + trailer
    /// frame). Decodes to: creditUsagePercent 99.0, currentPeriod weekly (type 2),
    /// 2026-06-30T21:36:52.140114Z → 2026-07-07T21:36:52.140114Z, isUnifiedBillingUser true —
    /// plus fields we don't map (2, 3, 4, 5, 7, 12, 13), which exercises unknown-field skipping
    /// on genuine wire bytes.
    static let capturedResponseBody = Data([
        0x00, 0x00, 0x00, 0x00, 0x52, // message frame header (82 bytes)
        0x0A, 0x50, 0x0D, 0x00, 0x00, 0xC6, 0x42, 0x12, 0x00, 0x1A, 0x00,
        0x22, 0x0B, 0x08, 0xF4, 0xED, 0x90, 0xD2, 0x06, 0x10, 0xD0, 0xF0, 0xE7, 0x42,
        0x2A, 0x0B, 0x08, 0xF4, 0xE2, 0xB5, 0xD2, 0x06, 0x10, 0xD0, 0xF0, 0xE7, 0x42,
        0x3A, 0x07, 0x08, 0x02, 0x15, 0x00, 0x00, 0xC6, 0x42,
        0x42, 0x1C, 0x08, 0x02,
        0x12, 0x0B, 0x08, 0xF4, 0xED, 0x90, 0xD2, 0x06, 0x10, 0xD0, 0xF0, 0xE7, 0x42,
        0x1A, 0x0B, 0x08, 0xF4, 0xE2, 0xB5, 0xD2, 0x06, 0x10, 0xD0, 0xF0, 0xE7, 0x42,
        0x58, 0x01, 0x62, 0x00, 0x68, 0x01,
        0x80, 0x00, 0x00, 0x00, 0x0F, // trailer frame header (15 bytes)
        0x67, 0x72, 0x70, 0x63, 0x2D, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x3A, 0x30, 0x0D, 0x0A // "grpc-status:0\r\n"
    ])

    static let capturedPeriodStart = Date(timeIntervalSince1970: 1_782_855_412 + 0.140114)
    static let capturedPeriodEnd = Date(timeIntervalSince1970: 1_783_460_212 + 0.140114)

    /// A synthetic response body with the fields the decoder reads, for shaping edge cases.
    static func responseBody(
        periodType: UInt64 = 2,
        percent: Float = 99.0,
        startSeconds: UInt64 = 1_782_855_412,
        endSeconds: UInt64 = 1_783_460_212
    ) -> Data {
        let period = field(1, varint: periodType)
            + field(2, message: timestamp(seconds: startSeconds))
            + field(3, message: timestamp(seconds: endSeconds))
        let config = field(1, float: percent) + field(8, message: period)
        return GRPCWebCodec.frame(field(1, message: config)) + okTrailerFrame
    }

    /// A trailer-only body reporting a gRPC failure inside an HTTP 200 (the endpoint's error shape).
    static func errorResponseBody(status: Int, message: String = "boom") -> Data {
        trailerFrame("grpc-status:\(status)\r\ngrpc-message:\(message)\r\n")
    }

    static var okTrailerFrame: Data {
        trailerFrame("grpc-status:0\r\n")
    }

    static func trailerFrame(_ text: String) -> Data {
        var framed = GRPCWebCodec.frame(Data(text.utf8))
        framed[framed.startIndex] = 0x80
        return framed
    }

    static func timestamp(seconds: UInt64, nanos: UInt64 = 140_114_000) -> Data {
        field(1, varint: seconds) + field(2, varint: nanos)
    }

    // MARK: - Protobuf wire-format builders

    static func varintBytes(_ value: UInt64) -> Data {
        var bytes = Data()
        var remaining = value
        repeat {
            let byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            bytes.append(remaining == 0 ? byte : byte | 0x80)
        } while remaining != 0
        return bytes
    }

    static func field(_ number: Int, varint value: UInt64) -> Data {
        varintBytes(UInt64(number) << 3 | 0) + varintBytes(value)
    }

    static func field(_ number: Int, float value: Float) -> Data {
        var bytes = varintBytes(UInt64(number) << 3 | 5)
        let pattern = value.bitPattern
        for i in 0..<4 { bytes.append(UInt8((pattern >> (8 * UInt32(i))) & 0xFF)) }
        return bytes
    }

    static func field(_ number: Int, fixed64 value: UInt64) -> Data {
        var bytes = varintBytes(UInt64(number) << 3 | 1)
        for i in 0..<8 { bytes.append(UInt8((value >> (8 * UInt64(i))) & 0xFF)) }
        return bytes
    }

    static func field(_ number: Int, message payload: Data) -> Data {
        varintBytes(UInt64(number) << 3 | 2) + varintBytes(UInt64(payload.count)) + payload
    }
}
