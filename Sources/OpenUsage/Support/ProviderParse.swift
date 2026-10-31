import Foundation

enum ProviderParse {
    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            AppLog.warn(.http, "response body is not valid JSON (\(data.count) bytes): \(error.localizedDescription)")
            return nil
        }
    }

    /// Permissive numeric read: accepts JSON numbers and numeric strings, rejecting booleans and
    /// non-finite values. `JSONSerialization` bridges booleans through `NSNumber`, so the Core
    /// Foundation type check is required to keep `true`/`false` from becoming `1`/`0`.
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let doubleValue = number.doubleValue
            return doubleValue.isFinite ? doubleValue : nil
        }
        if let string = value as? String {
            let doubleValue = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            return doubleValue?.isFinite == true ? doubleValue : nil
        }
        return nil
    }

    /// `Int(_:)` traps on a value outside the Int range; this returns nil instead.
    static func int(_ value: Double) -> Int? {
        abs(value) < Double(Int.max) ? Int(value) : nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }

    static func centsToDollars(_ cents: Double) -> Double {
        cents.rounded() / 100
    }

    static func jwtPayload(_ token: String) -> [String: Any]? {
        guard let data = jwtPayloadData(token) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func jwtPayloadData(_ token: String) -> Data? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) {
            payload.append("=")
        }
        return Data(base64Encoded: payload)
    }

    static func jwtExpiry(_ token: String) -> Date? {
        number(jwtPayload(token)?["exp"]).map(Date.init(timeIntervalSince1970:))
    }
}

extension String {
    /// Percent-encode one `application/x-www-form-urlencoded` value. Only the ASCII characters
    /// RFC 3986 defines as unreserved pass through; spaces use `%20` so a literal `+` remains
    /// distinguishable from a form-space separator.
    var urlFormEncoded: String {
        var encoded = ""
        encoded.reserveCapacity(utf8.count)

        for byte in utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

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
