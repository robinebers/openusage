import Foundation

/// A hand-rolled reader for the protobuf wire format, just enough to decode the small binary
/// responses OpenUsage consumes (today: Grok's credits config). Decoding a whole message up front
/// and looking fields up by number means unknown fields are skipped by construction — providers'
/// schemas drift fast, and a new field must never break the read of the ones we know.
///
/// Supported wire types: 0 (varint), 1 (fixed64), 2 (length-delimited), 5 (fixed32). The
/// long-deprecated group types (3/4) are treated as malformed input.
enum ProtobufWireError: Error, Equatable, LocalizedError {
    case truncated
    case varintOverflow
    case invalidFieldNumber
    case unsupportedWireType(Int)

    var errorDescription: String? {
        switch self {
        case .truncated: return "Protobuf message was truncated."
        case .varintOverflow: return "Protobuf varint exceeded 64 bits."
        case .invalidFieldNumber: return "Protobuf field number was invalid."
        case .unsupportedWireType(let type): return "Protobuf wire type \(type) is unsupported."
        }
    }
}

/// One decoded field value, tagged by wire type. Interpretation (signedness, float bit patterns,
/// nested messages) is the caller's job via the `ProtobufMessage` accessors.
enum ProtobufFieldValue: Equatable, Sendable {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case lengthDelimited(Data)
}

/// A fully decoded protobuf message: every field parsed, unknown numbers simply never asked for.
/// For repeated fields the accessors return the last occurrence (proto3 last-one-wins semantics);
/// none of the messages we read use repeated fields we care about.
struct ProtobufMessage {
    private let fields: [(number: Int, value: ProtobufFieldValue)]

    init(_ data: Data) throws {
        var decoded: [(Int, ProtobufFieldValue)] = []
        let bytes = Data(data) // normalize slice indices to zero-based
        var offset = 0

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard offset < bytes.count else { throw ProtobufWireError.truncated }
                guard shift < 64 else { throw ProtobufWireError.varintOverflow }
                let byte = bytes[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        while offset < bytes.count {
            let tag = try readVarint()
            let number = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            guard number >= 1 else { throw ProtobufWireError.invalidFieldNumber }

            switch wireType {
            case 0:
                decoded.append((number, .varint(try readVarint())))
            case 1:
                guard offset + 8 <= bytes.count else { throw ProtobufWireError.truncated }
                var value: UInt64 = 0
                for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
                offset += 8
                decoded.append((number, .fixed64(value)))
            case 2:
                let length = try readVarint()
                guard length <= UInt64(bytes.count - offset) else { throw ProtobufWireError.truncated }
                let payload = bytes.subdata(in: offset..<(offset + Int(length)))
                offset += Int(length)
                decoded.append((number, .lengthDelimited(payload)))
            case 5:
                guard offset + 4 <= bytes.count else { throw ProtobufWireError.truncated }
                var value: UInt32 = 0
                for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
                offset += 4
                decoded.append((number, .fixed32(value)))
            default:
                throw ProtobufWireError.unsupportedWireType(wireType)
            }
        }
        fields = decoded
    }

    private func last(_ number: Int) -> ProtobufFieldValue? {
        fields.last(where: { $0.number == number })?.value
    }

    func varint(_ number: Int) -> UInt64? {
        if case .varint(let value)? = last(number) { return value }
        return nil
    }

    /// A `float` field (fixed32 bit pattern reinterpreted).
    func float(_ number: Int) -> Float? {
        if case .fixed32(let value)? = last(number) { return Float(bitPattern: value) }
        return nil
    }

    func bytes(_ number: Int) -> Data? {
        if case .lengthDelimited(let value)? = last(number) { return value }
        return nil
    }

    /// Decode a length-delimited field as a nested message. `nil` when the field is absent;
    /// throws when it is present but not valid protobuf.
    func message(_ number: Int) throws -> ProtobufMessage? {
        guard let payload = bytes(number) else { return nil }
        return try ProtobufMessage(payload)
    }
}
