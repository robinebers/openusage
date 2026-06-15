import Foundation

/// Shared, behavior-free parsing chores used by more than one provider. Consolidated here so a new
/// provider reuses the same JSON/number/percent handling instead of copying it.
enum ProviderParse {
    /// Decode a top-level JSON object from raw response data.
    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Permissive numeric read: accepts JSON numbers and numeric strings, rejecting non-finite values.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let doubleValue = number.doubleValue
            return doubleValue.isFinite ? doubleValue : nil
        }
        if let string = value as? String {
            let doubleValue = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            return doubleValue?.isFinite == true ? doubleValue : nil
        }
        return nil
    }

    /// Clamp a percentage into 0...100, treating non-finite input as 0.
    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    /// Convert integer cents to dollars: snap to whole cents, then scale. Inputs are already integer
    /// cents from the providers' APIs; rounding guards against float drift before the divide.
    static func centsToDollars(_ cents: Double) -> Double {
        cents.rounded() / 100
    }

    /// Decode `T` from JSON text, falling back to a hex-encoded JSON blob — some providers store their
    /// credentials/auth file as hex (optionally `0x`-prefixed) rather than plain JSON.
    static func decodeJSONWithHexFallback<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        if let decoded = decodeJSON(text, as: type) { return decoded }

        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex = String(hex.dropFirst(2))
        }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else {
            return nil
        }

        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
        return decodeJSON(decoded, as: type)
    }

    private static func decodeJSON<T: Decodable>(_ text: String, as type: T.Type) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Decode a JWT's payload (the middle dot-separated segment) as a JSON object. Base64url is
    /// translated to standard base64 and padded before decoding.
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }
}

extension String {
    /// Percent-encode for use as an `application/x-www-form-urlencoded` value.
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    /// `nil` when the string is empty, otherwise the string itself — for treating "" as "missing".
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    /// Drop any trailing slashes, for joining base URLs and paths.
    var trimmingTrailingSlashes: String {
        var copy = self
        while copy.hasSuffix("/") {
            copy.removeLast()
        }
        return copy
    }

    /// Title-case a provider plan name: split on `isSeparator`, upper-case each word's first character,
    /// and re-join with single spaces. When `lowercasingTail` is true the rest of each word is
    /// lower-cased (e.g. "PRO PLAN" → "Pro Plan"); otherwise it's preserved (e.g. "pro_plus" → "Pro Plus").
    func titleCased(separator isSeparator: (Character) -> Bool, lowercasingTail: Bool = false) -> String {
        split(whereSeparator: isSeparator)
            .map { word in
                let head = word.prefix(1).uppercased()
                let tail = lowercasingTail ? word.dropFirst().lowercased() : String(word.dropFirst())
                return head + tail
            }
            .joined(separator: " ")
    }
}
