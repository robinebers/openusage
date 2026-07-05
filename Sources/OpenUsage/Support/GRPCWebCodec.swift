import Foundation

/// Minimal gRPC-web framing for the binary RPCs OpenUsage speaks over plain HTTPS (today: Grok's
/// credits config). Only the unary shape is supported: one request message out, one response body
/// back containing at most one message frame plus one trailer frame carrying `grpc-status`.
///
/// Parsing is deliberately strict and throwing, never tolerant: the server reports errors inside an
/// HTTP 200 via the trailer, so a "best effort" parse that drops a truncated trailer could keep the
/// message frame and manufacture data out of an error response. Anything unexpected — truncation,
/// compression, extra frames, a missing status — is an error for the caller to surface.
enum GRPCWebCodecError: Error, Equatable, LocalizedError {
    case truncatedResponse
    case compressedFrame
    case unknownFrameFlag(UInt8)
    case missingTrailerStatus
    case multipleTrailers
    case unexpectedMessageCount(Int)

    var errorDescription: String? {
        switch self {
        case .truncatedResponse: return "gRPC-web response was truncated."
        case .compressedFrame: return "gRPC-web response used unsupported compression."
        case .unknownFrameFlag(let flag): return "gRPC-web response contained an unknown frame flag (\(flag))."
        case .missingTrailerStatus: return "gRPC-web response carried no grpc-status trailer."
        case .multipleTrailers: return "gRPC-web response carried more than one trailer frame."
        case .unexpectedMessageCount(let count): return "gRPC-web success carried \(count) message frames instead of 1."
        }
    }
}

/// A parsed unary gRPC-web response: the server's status (0 = OK) with its optional human-readable
/// message, and the single protobuf message payload (present exactly when the status is 0).
struct GRPCWebUnaryResponse: Equatable, Sendable {
    var status: Int
    var statusMessage: String?
    var message: Data?
}

enum GRPCWebCodec {
    private static let dataFrameFlag: UInt8 = 0x00
    private static let trailerFrameFlag: UInt8 = 0x80
    private static let compressionBit: UInt8 = 0x01

    /// Wrap a protobuf message in a gRPC-web data frame: 1 flag byte (0x00, uncompressed) + 4-byte
    /// big-endian length + payload.
    static func frame(_ message: Data) -> Data {
        var framed = Data(capacity: 5 + message.count)
        framed.append(dataFrameFlag)
        let length = UInt32(message.count)
        framed.append(UInt8((length >> 24) & 0xFF))
        framed.append(UInt8((length >> 16) & 0xFF))
        framed.append(UInt8((length >> 8) & 0xFF))
        framed.append(UInt8(length & 0xFF))
        framed.append(message)
        return framed
    }

    /// Strictly parse a unary response body. Throws on truncation, compression, unknown flags, a
    /// missing/duplicated trailer, or a status-0 body without exactly one message frame.
    static func parseUnary(_ body: Data) throws -> GRPCWebUnaryResponse {
        var messages: [Data] = []
        var trailer: [String: String]?

        // Data(...) slices can have a non-zero startIndex; normalize to relative offsets.
        let bytes = Data(body)
        var offset = 0
        while offset < bytes.count {
            guard offset + 5 <= bytes.count else { throw GRPCWebCodecError.truncatedResponse }
            let flag = bytes[offset]
            let length = Int(bytes[offset + 1]) << 24 | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])
            offset += 5
            guard offset + length <= bytes.count else { throw GRPCWebCodecError.truncatedResponse }
            let payload = bytes.subdata(in: offset..<(offset + length))
            offset += length

            guard flag & compressionBit == 0 else { throw GRPCWebCodecError.compressedFrame }
            switch flag {
            case dataFrameFlag:
                messages.append(payload)
            case trailerFrameFlag:
                guard trailer == nil else { throw GRPCWebCodecError.multipleTrailers }
                trailer = parseTrailer(payload)
            default:
                throw GRPCWebCodecError.unknownFrameFlag(flag)
            }
        }

        guard let trailer, let statusText = trailer["grpc-status"], let status = Int(statusText) else {
            throw GRPCWebCodecError.missingTrailerStatus
        }
        if status == 0, messages.count != 1 {
            throw GRPCWebCodecError.unexpectedMessageCount(messages.count)
        }
        return GRPCWebUnaryResponse(
            status: status,
            statusMessage: trailer["grpc-message"],
            message: messages.first
        )
    }

    /// Trailer frames carry HTTP/1-style `name: value` lines separated by CRLF, names case-insensitive.
    private static func parseTrailer(_ payload: Data) -> [String: String] {
        var headers: [String: String] = [:]
        let text = String(decoding: payload, as: UTF8.self)
        for line in text.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                headers[name] = value
            }
        }
        return headers
    }
}
