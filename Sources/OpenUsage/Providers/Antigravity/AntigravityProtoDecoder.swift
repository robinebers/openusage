import Foundation

/// Decodes the generation-accounting fields in Antigravity's undocumented conversation protobufs.
/// Based on FelixIsaac's original implementation in openusage#1058 and the follow-up in #1120.
enum AntigravityProtoDecoder {
    enum WireValue {
        case varint(UInt64)
        case bytes([UInt8])
        case fixed64
        case fixed32
    }

    struct GenerationEvent: Equatable, Sendable {
        static let unknownModel = "Unknown Antigravity Model"

        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var timestampSeconds: Int64
    }

    static func decodeVarint(_ bytes: [UInt8], at offset: Int = 0) -> (value: UInt64, nextOffset: Int)? {
        guard offset >= 0, offset < bytes.count else { return nil }

        var value: UInt64 = 0
        for byteIndex in 0..<10 {
            let position = offset + byteIndex
            guard position < bytes.count else { return nil }

            let byte = bytes[position]
            let payload = UInt64(byte & 0x7f)
            guard byteIndex < 9 || payload <= 1 else { return nil }

            value |= payload << (byteIndex * 7)
            if byte & 0x80 == 0 {
                return (value, position + 1)
            }
        }
        return nil
    }

    static func fields(in bytes: [UInt8]) -> [(number: UInt32, value: WireValue)] {
        var fields: [(number: UInt32, value: WireValue)] = []
        var offset = 0

        while offset < bytes.count {
            guard let tag = decodeVarint(bytes, at: offset),
                  let number = UInt32(exactly: tag.value >> 3), number != 0
            else { return fields }

            switch tag.value & 0x7 {
            case 0:
                guard let field = decodeVarint(bytes, at: tag.nextOffset) else { return fields }
                fields.append((number, .varint(field.value)))
                offset = field.nextOffset

            case 1:
                guard bytes.count - tag.nextOffset >= 8 else { return fields }
                fields.append((number, .fixed64))
                offset = tag.nextOffset + 8

            case 2:
                guard let length = decodeVarint(bytes, at: tag.nextOffset),
                      length.value <= UInt64(bytes.count - length.nextOffset),
                      let count = Int(exactly: length.value)
                else { return fields }

                let end = length.nextOffset + count
                fields.append((number, .bytes(Array(bytes[length.nextOffset..<end]))))
                offset = end

            case 5:
                guard bytes.count - tag.nextOffset >= 4 else { return fields }
                fields.append((number, .fixed32))
                offset = tag.nextOffset + 4

            default:
                return fields
            }
        }

        return fields
    }

    static func bytesField(_ number: UInt32, in fields: [(number: UInt32, value: WireValue)]) -> [UInt8]? {
        for field in fields where field.number == number {
            if case .bytes(let bytes) = field.value { return bytes }
        }
        return nil
    }

    static func varintField(_ number: UInt32, in fields: [(number: UInt32, value: WireValue)]) -> UInt64? {
        for field in fields where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    /// `gen_metadata.data` wraps its event in field 1: model 19, token counts 4, and timestamp 9.
    /// An absent model remains visibly unpriced instead of silently borrowing another Gemini rate.
    static func generationEvent(from blob: [UInt8]) -> GenerationEvent? {
        let topLevel = fields(in: blob)
        guard let wrappedBytes = bytesField(1, in: topLevel) else { return nil }
        let wrapped = fields(in: wrappedBytes)

        let decodedModel = bytesField(19, in: wrapped).flatMap { String(bytes: $0, encoding: .utf8) }
        let model = decodedModel?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let usageBytes = bytesField(4, in: wrapped) else { return nil }
        let usage = fields(in: usageBytes)

        guard let systemPromptTokens = Int(exactly: varintField(1, in: usage) ?? 0),
              let inputTokens = Int(exactly: varintField(2, in: usage) ?? 0),
              let outputTokens = Int(exactly: varintField(3, in: usage) ?? 0),
              let cacheReadTokens = Int(exactly: varintField(5, in: usage) ?? 0)
        else { return nil }

        let billableInputTokens = systemPromptTokens.addingReportingOverflow(inputTokens)
        guard !billableInputTokens.overflow,
              billableInputTokens.partialValue != 0 || outputTokens != 0 || cacheReadTokens != 0,
              let timingBytes = bytesField(9, in: wrapped),
              let wallClockBytes = bytesField(4, in: fields(in: timingBytes)),
              let timestamp = varintField(1, in: fields(in: wallClockBytes)),
              let timestampSeconds = Int64(exactly: timestamp), timestampSeconds > 0
        else { return nil }

        return GenerationEvent(
            model: model.flatMap { $0.isEmpty ? nil : $0 } ?? GenerationEvent.unknownModel,
            inputTokens: billableInputTokens.partialValue,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            timestampSeconds: timestampSeconds
        )
    }
}
