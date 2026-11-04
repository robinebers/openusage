import Foundation

/// A banked Z.ai reset refills one window: the five-hour Session or the Weekly.
enum ZAIResetWindow: String, CaseIterable, Sendable {
    case fiveHour = "FIVE_HOUR"
    case week = "WEEK"

    var title: String {
        switch self {
        case .fiveHour: "Session"
        case .week: "Weekly"
        }
    }

    var confirmDetail: String {
        "Refills your \(title.lowercased()) limit now. This can't be undone."
    }

    fileprivate var listKey: String {
        switch self {
        case .fiveHour: "fiveHourResets"
        case .week: "weekResets"
        }
    }
}

/// One available reset record. A claim names its record exactly: two resets can share an expiry.
struct ZAIReset: Hashable, Sendable {
    let window: ZAIResetWindow
    let recordID: Int
    let expiresAt: Date
    let grantType: String
}

enum ZAIResetsMapper {
    /// The available, unexpired resets of both windows, earliest first.
    static func resets(from body: Data, now: Date) throws -> [ZAIReset] {
        guard let root = ProviderParse.jsonObject(body), (root["success"] as? Bool) != false,
              let data = root["data"] as? [String: Any]
        else {
            throw ProviderError.invalidResponse
        }
        var resets: [ZAIReset] = []
        for window in ZAIResetWindow.allCases {
            guard let records = data[window.listKey] else { continue }
            guard let records = records as? [[String: Any]] else { throw ProviderError.invalidResponse }
            for record in records where (record["available"] as? Bool) == true {
                guard let id = record["recordId"] as? Int,
                      let expiresAt = (record["expireTime"] as? String).flatMap(expiry),
                      let grantType = record["grantType"] as? String, !grantType.isEmpty
                else {
                    throw ProviderError.invalidResponse
                }
                if expiresAt > now {
                    resets.append(ZAIReset(window: window, recordID: id, expiresAt: expiresAt, grantType: grantType))
                }
            }
        }
        return resets.sorted { ($0.expiresAt, $0.recordID) < ($1.expiresAt, $1.recordID) }
    }

    static func line(_ resets: [ZAIReset]) -> MetricLine {
        .values(
            label: "Rate Limit Resets",
            values: [MetricValue(number: Double(resets.count), kind: .count, label: "available")],
            expiriesAt: resets.map(\.expiresAt)
        )
    }

    /// Only a successful status with `success: true` spent the reset.
    static func claimOutcome(from response: HTTPResponse) -> ResetClaimOutcome {
        if ProviderError.isAuthFailure(response) { return .failed(.signInExpired) }
        guard (200..<300).contains(response.statusCode),
              (ProviderParse.jsonObject(response.body)?["success"] as? Bool) == true
        else {
            return .failed(.refused)
        }
        return .success
    }

    /// Z.ai writes expiries as `yyyy-MM-dd HH:mm:ss` in its own time zone, UTC+8.
    static func expiry(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}
