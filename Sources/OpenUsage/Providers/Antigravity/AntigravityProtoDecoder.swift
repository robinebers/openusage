import Foundation

/// Minimal reverse-engineered protobuf reader for Antigravity's `gen_metadata.data` blobs (no `.proto`
/// schema is published). Only what's needed to pull model/token/timestamp fields out of a `GenEvent`-
/// shaped message: varint decoding, wire-type dispatch, and field lookup by number. Ported field-for-
/// field from the Rust implementation in `tokenusage` (`src/pipeline/parsing.rs`), which was validated
/// against real local Antigravity data.
enum ProtoWireVal {
    case varint(UInt64)
    case bytes([UInt8])
    case fixed64
    case fixed32
}

/// LEB128 varint at `offset`; returns the value and the offset just past it, or nil on truncation/
/// overflow (more than 10 continuation bytes, i.e. shift >= 64).
func decodeVarint(_ bytes: [UInt8], _ offset: Int) -> (UInt64, Int)? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    var pos = offset
    while pos < bytes.count {
        let byte = bytes[pos]
        result |= UInt64(byte & 0x7f) << shift
        pos += 1
        if byte & 0x80 == 0 {
            return (result, pos)
        }
        shift += 7
        if shift >= 64 { return nil }
    }
    return nil
}

/// Walks a message's top-level fields (tag = `(field_number << 3) | wire_type`). Stops and returns
/// whatever was parsed so far on any malformed/truncated field, rather than throwing — callers treat a
/// short result the same as "field not found".
func parseProtoFields(_ bytes: [UInt8]) -> [(UInt32, ProtoWireVal)] {
    var fields: [(UInt32, ProtoWireVal)] = []
    var offset = 0
    while offset < bytes.count {
        guard let (tag, afterTag) = decodeVarint(bytes, offset) else { return fields }
        let fieldNumber = UInt32(truncatingIfNeeded: tag >> 3)
        let wireType = tag & 0x7
        switch wireType {
        case 0:
            guard let (value, next) = decodeVarint(bytes, afterTag) else { return fields }
            fields.append((fieldNumber, .varint(value)))
            offset = next
        case 1:
            guard afterTag + 8 <= bytes.count else { return fields }
            fields.append((fieldNumber, .fixed64))
            offset = afterTag + 8
        case 2:
            guard let (len64, afterLen) = decodeVarint(bytes, afterTag) else { return fields }
            let len = Int(len64)
            guard len >= 0, afterLen + len <= bytes.count else { return fields }
            fields.append((fieldNumber, .bytes(Array(bytes[afterLen..<(afterLen + len)]))))
            offset = afterLen + len
        case 5:
            guard afterTag + 4 <= bytes.count else { return fields }
            fields.append((fieldNumber, .fixed32))
            offset = afterTag + 4
        default:
            return fields
        }
    }
    return fields
}

func findProtoBytes(_ fields: [(UInt32, ProtoWireVal)], _ fieldNumber: UInt32) -> [UInt8]? {
    for (number, value) in fields {
        if number == fieldNumber, case .bytes(let bytes) = value { return bytes }
    }
    return nil
}

func findProtoVarint(_ fields: [(UInt32, ProtoWireVal)], _ fieldNumber: UInt32) -> UInt64? {
    for (number, value) in fields {
        if number == fieldNumber, case .varint(let v) = value { return v }
    }
    return nil
}

struct ParsedAntigravityGenEvent: Equatable {
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var timestampSecs: Int64
}

/// Pulls model + token accounting + timestamp out of one `gen_metadata.data` blob.
///
/// Shape (field numbers reverse-engineered, no `.proto` available):
/// - top-level field 1: the wrapped `GenEvent` message
///   - field 19: model id (string), defaults to `gemini-3.6-flash` when absent/empty
///   - field 4: token usage message — field 2 input, field 3 output, field 5 cache-read (all varints)
///   - field 9: timing message → field 4 wall-clock message → field 1: unix seconds (varint)
///
/// Returns nil when the wrapper is missing/malformed or every token count is zero (a non-generation
/// event, e.g. a tool-call-only step).
func extractAntigravityGenEvent(_ blob: [UInt8]) -> ParsedAntigravityGenEvent? {
    let top = parseProtoFields(blob)
    guard let wrapperBytes = findProtoBytes(top, 1) else { return nil }
    let wrapper = parseProtoFields(wrapperBytes)

    var model = "gemini-3.6-flash"
    if let modelBytes = findProtoBytes(wrapper, 19),
       let decoded = String(bytes: modelBytes, encoding: .utf8),
       !decoded.isEmpty {
        model = decoded
    }

    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    if let usageBytes = findProtoBytes(wrapper, 4) {
        let usage = parseProtoFields(usageBytes)
        inputTokens = Int(findProtoVarint(usage, 2) ?? 0)
        outputTokens = Int(findProtoVarint(usage, 3) ?? 0)
        cacheReadTokens = Int(findProtoVarint(usage, 5) ?? 0)
    }

    var timestampSecs: Int64 = 0
    if let timingBytes = findProtoBytes(wrapper, 9) {
        let timing = parseProtoFields(timingBytes)
        if let wallClockBytes = findProtoBytes(timing, 4) {
            let wallClock = parseProtoFields(wallClockBytes)
            timestampSecs = Int64(findProtoVarint(wallClock, 1) ?? 0)
        }
    }

    guard inputTokens != 0 || outputTokens != 0 || cacheReadTokens != 0 else { return nil }

    return ParsedAntigravityGenEvent(
        model: model,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        timestampSecs: timestampSecs
    )
}
