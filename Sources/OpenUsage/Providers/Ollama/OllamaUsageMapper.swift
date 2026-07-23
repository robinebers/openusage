import Foundation

struct OllamaUsageData: Sendable {
    var plan: String?
    var sessionPercent: Double
    var weeklyPercent: Double
    var sessionResetsAt: Date?
    var weeklyResetsAt: Date?
    var source: String
}

enum OllamaUsageMapper {
    static let sessionMs = 5 * 60 * 60 * 1000
    static let weekMs = 7 * 24 * 60 * 60 * 1000

    static func parseAPIUsage(_ data: Data) -> OllamaUsageData? {
        guard let json = ProviderParse.jsonObject(data) else { return nil }
        let body = (json["data"] as? [String: Any]) ?? json

        let session = nestedObject(body, keys: ["session", "session_usage", "sessionUsage"])
        let weekly = nestedObject(body, keys: ["weekly", "weekly_usage", "weeklyUsage"])

        let sessionPercent = clampPercent(
            session?["used_percent"] ?? session?["usedPercent"] ?? session?["percent"] ?? session?["percentage"]
            ?? body["session_percent"] ?? body["sessionPercent"]
        )
        let weeklyPercent = clampPercent(
            weekly?["used_percent"] ?? weekly?["usedPercent"] ?? weekly?["percent"] ?? weekly?["percentage"]
            ?? body["weekly_percent"] ?? body["weeklyPercent"]
        )

        guard let sessionPercent, let weeklyPercent else { return nil }

        return OllamaUsageData(
            plan: (body["plan"] ?? body["tier"] ?? body["subscription"]).flatMap { ($0 as? String)?.nilIfEmpty },
            sessionPercent: sessionPercent,
            weeklyPercent: weeklyPercent,
            sessionResetsAt: (session?["resets_at"] ?? session?["resetsAt"] ?? body["session_resets_at"]).flatMap { ($0 as? String).flatMap(OpenUsageISO8601.date) },
            weeklyResetsAt: (weekly?["resets_at"] ?? weekly?["resetsAt"] ?? body["weekly_resets_at"]).flatMap { ($0 as? String).flatMap(OpenUsageISO8601.date) },
            source: "API"
        )
    }

    static func parseSettingsHTML(_ html: String, now: Date) -> OllamaUsageData? {
        guard html.contains("Cloud Usage") else { return nil }

        let text = stripHTML(html)
        let percentages = extractPercentages(text)
        guard percentages.count >= 2,
              let sessionPercent = percentages[0],
              let weeklyPercent = percentages[1] else { return nil }

        let resetValues = extractDataTimeValues(html)
        let plan = extractPlan(text)

        let sessionSection = sectionBetween(text, startLabel: "Session usage", endLabel: "Weekly usage")
        let weeklySection = sectionBetween(text, startLabel: "Weekly usage", endLabel: "Notify me")

        return OllamaUsageData(
            plan: plan,
            sessionPercent: sessionPercent,
            weeklyPercent: weeklyPercent,
            sessionResetsAt: resetValues.first ?? relativeReset(sessionSection, now: now),
            weeklyResetsAt: resetValues.count > 1 ? resetValues[1] : relativeReset(weeklySection, now: now),
            source: "settings"
        )
    }

    static func buildLines(from data: OllamaUsageData) -> [MetricLine] {
        [
            .progress(
                label: "Session",
                used: data.sessionPercent,
                limit: 100,
                format: .percent,
                resetsAt: data.sessionResetsAt,
                periodDurationMs: sessionMs
            ),
            .progress(
                label: "Weekly",
                used: data.weeklyPercent,
                limit: 100,
                format: .percent,
                resetsAt: data.weeklyResetsAt,
                periodDurationMs: weekMs
            )
        ]
    }

    // MARK: - Helpers

    private static func nestedObject(_ dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func clampPercent(_ value: Any?) -> Double? {
        let n: Double?
        if let d = value as? Double { n = d }
        else if let s = value as? String { n = Double(s) }
        else { return nil }
        guard let n, n.isFinite else { return nil }
        return max(0, min(100, n))
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: /<script[\s\S]*?<\/script>/, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: /<style[\s\S]*?<\/style>/, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: /<[^>]+>/, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: /&#(\d+);/, with: "") { m in
            guard let n = Int(m.output.1) else { return "" }
            return String(Character(UnicodeScalar(n)!))
        }
        text = text.replacingOccurrences(of: /&#x([0-9a-f]+);/, with: "") { m in
            guard let n = Int(m.output.1, radix: 16) else { return "" }
            return String(Character(UnicodeScalar(n)!))
        }
        return text.replacingOccurrences(of: /\s+/, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func extractPercentages(_ text: String) -> [Double?] {
        var results: [Double?] = []
        let regex = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)%\s*used"#, options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, stop in
            guard results.count < 2, let match else { return }
            let nsText = text as NSString
            let numStr = nsText.substring(with: match.range(at: 1))
            results.append(Double(numStr))
        }
        return results
    }

    private static func extractDataTimeValues(_ html: String) -> [Date?] {
        var results: [Date?] = []
        let regex = try! NSRegularExpression(pattern: #"data-time="([^"]+)""#)
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match else { return }
            let nsText = html as NSString
            let value = nsText.substring(with: match.range(at: 1))
            results.append(OpenUsageISO8601.date(from: value))
        }
        return results
    }

    private static func extractPlan(_ text: String) -> String? {
        let regex = try! NSRegularExpression(pattern: #"Cloud Usage\s+(Free|Pro|Max|Team)\b"#, options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let nsText = text as NSString
        return nsText.substring(with: match.range(at: 1))
    }

    private static func sectionBetween(_ text: String, startLabel: String, endLabel: String) -> String {
        guard let start = text.range(of: startLabel, options: .caseInsensitive) else { return "" }
        let after = String(text[start.lowerBound...])
        guard let end = after.range(of: endLabel, options: .caseInsensitive) else { return after }
        return String(after[..<end.lowerBound])
    }

    private static func relativeReset(_ section: String, now: Date) -> Date? {
        let pattern = try! NSRegularExpression(pattern: #"Resets in\s+(?:less than\s+)?(\d+(?:\.\d+)?)\s*(second|seconds|minute|minutes|min|m|hour|hours|h|day|days|d|week|weeks|w)"#, options: .caseInsensitive)
        let range = NSRange(section.startIndex..., in: section)
        guard let match = pattern.firstMatch(in: section, range: range) else { return nil }
        let nsText = section as NSString
        let amountStr = nsText.substring(with: match.range(at: 1))
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        guard let amount = Double(amountStr), amount >= 0 else { return nil }

        let factor: Double
        if unit.hasPrefix("second") || unit == "s" { factor = 1 }
        else if unit.hasPrefix("minute") || unit == "min" || unit == "m" { factor = 60 }
        else if unit.hasPrefix("hour") || unit == "h" { factor = 3600 }
        else if unit.hasPrefix("day") || unit == "d" { factor = 86400 }
        else if unit.hasPrefix("week") || unit == "w" { factor = 604800 }
        else { return nil }

        return now.addingTimeInterval(amount * factor)
    }
}
