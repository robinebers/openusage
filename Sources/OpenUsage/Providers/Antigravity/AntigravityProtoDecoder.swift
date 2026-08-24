import Foundation

/// Decodes the generation-accounting fields in Antigravity's undocumented conversation protobufs.
/// Based on FelixIsaac's original implementation in openusage#1058 and the follow-up in #1120.
enum AntigravityProtoDecoder {
    enum WireValue {
        case varint(UInt64)
        case bytes([UInt8])
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

    private static func field(_ requested: UInt32, in bytes: [UInt8]) -> WireValue? {
        var offset = 0

        while offset < bytes.count {
            guard let tag = decodeVarint(bytes, at: offset),
                  let number = UInt32(exactly: tag.value >> 3), number != 0
            else { return nil }

            switch tag.value & 0x7 {
            case 0:
                guard let value = decodeVarint(bytes, at: tag.nextOffset) else { return nil }
                if number == requested { return .varint(value.value) }
                offset = value.nextOffset

            case 2:
                guard let length = decodeVarint(bytes, at: tag.nextOffset),
                      length.value <= UInt64(bytes.count - length.nextOffset),
                      let count = Int(exactly: length.value)
                else { return nil }

                let end = length.nextOffset + count
                if number == requested { return .bytes(Array(bytes[length.nextOffset..<end])) }
                offset = end

            case 1, 5:
                let width = tag.value & 0x7 == 1 ? 8 : 4
                guard bytes.count - tag.nextOffset >= width else { return nil }
                offset = tag.nextOffset + width

            default:
                return nil
            }
        }
        return nil
    }

    static func bytesField(_ number: UInt32, in bytes: [UInt8]) -> [UInt8]? {
        guard case .bytes(let value) = field(number, in: bytes) else { return nil }
        return value
    }

    static func varintField(_ number: UInt32, in bytes: [UInt8]) -> UInt64? {
        guard case .varint(let value) = field(number, in: bytes) else { return nil }
        return value
    }

    /// `gen_metadata.data` wraps its event in field 1: model 19, token counts 4, and timestamp 9.
    /// An absent model remains visibly unpriced instead of silently borrowing another Gemini rate.
    static func generationEvent(from blob: [UInt8]) -> GenerationEvent? {
        guard let wrapped = bytesField(1, in: blob) else { return nil }

        let decodedModel = bytesField(19, in: wrapped).flatMap { String(bytes: $0, encoding: .utf8) }
        let model = decodedModel?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let usage = bytesField(4, in: wrapped) else { return nil }

        guard let systemPromptTokens = Int(exactly: varintField(1, in: usage) ?? 0),
              let inputTokens = Int(exactly: varintField(2, in: usage) ?? 0),
              let outputTokens = Int(exactly: varintField(3, in: usage) ?? 0),
              let cacheReadTokens = Int(exactly: varintField(5, in: usage) ?? 0)
        else { return nil }

        let billableInputTokens = systemPromptTokens.addingReportingOverflow(inputTokens)
        guard !billableInputTokens.overflow,
              billableInputTokens.partialValue != 0 || outputTokens != 0 || cacheReadTokens != 0,
              let timingBytes = bytesField(9, in: wrapped),
              let wallClockBytes = bytesField(4, in: timingBytes),
              let timestamp = varintField(1, in: wallClockBytes),
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
