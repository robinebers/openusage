import Foundation

/// One parsed row from Cursor's CSV usage export. `imputedCostDollars` is the locally priced dollar
/// amount (server CSV tokens × the shared model pricing); `nil` when no pricing source knows the
/// model — those rows contribute tokens but flag the day's cost as incomplete. Ported from
/// `../cursorcat/Sources/CursorCat/API/UsageCSV.swift`, dropping the actual-cost / CostMode path for v1.
struct CursorUsageCSVRow: Sendable, Equatable {
    var date: Date
    var model: String
    var tokens: TokenBreakdown
    var imputedCostDollars: Double?
}

enum CursorUsageCSV {
    // Date parsing runs once per row of a potentially large export; the three fixed-format parsers are
    // stateless after configuration, so they're built once instead of per call. DateFormatter and
    // ISO8601DateFormatter are thread-safe for parsing; `nonisolated(unsafe)` shares the immutable
    // instances without per-call allocation.
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let plainDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Pure parser: maps Cursor's exported CSV text into priced rows. Rows with an unparseable date or
    /// header are skipped.
    ///
    /// Cursor's CSV rows are aggregates, not individual requests, so long-context thresholds and Max
    /// Mode uplift cannot be applied reliably from row totals; rows bill at the base model API rate.
    static func parse(csv: String, pricing: ModelPricing) -> [CursorUsageCSVRow] {
        var rows: [CursorUsageCSVRow] = []
        CursorCSVParser.forEachRecord(in: csv) { r in
            guard let dateStr = r["Date"]?.trimmingCharacters(in: .whitespaces),
                  !dateStr.isEmpty,
                  let date = parseDate(dateStr)
            else { return }

            let model = (r["Model"] ?? "").trimmingCharacters(in: .whitespaces)
            // The CSV's "Input (w/ Cache Write)" tokens were written to the prompt cache; Anthropic
            // bills those at the 5-minute cache-write rate, other providers at the input rate (their
            // pricing entries carry cacheWrite == input).
            let tokens = TokenBreakdown(
                input: parseIntValue(r["Input (w/o Cache Write)"] ?? ""),
                cacheWrite5m: parseIntValue(r["Input (w/ Cache Write)"] ?? ""),
                cacheRead: parseIntValue(r["Cache Read"] ?? ""),
                output: parseIntValue(r["Output Tokens"] ?? "")
            )

            rows.append(CursorUsageCSVRow(
                date: date,
                model: model,
                tokens: tokens,
                imputedCostDollars: pricing.estimatedCostDollars(
                    model: model,
                    tokens: tokens,
                    applyLongContextRates: false
                )
            ))
        }
        return rows
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let d = isoFractional.date(from: raw) { return d }
        if let d = iso.date(from: raw) { return d }
        return plainDateTime.date(from: raw)
    }

    private static func parseIntValue(_ raw: String) -> Int {
        let normalized = raw.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return 0 }
        return Int(normalized) ?? 0
    }
}
