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

struct CursorUsageCSVParseResult: Sendable, Equatable {
    var rows: [CursorUsageCSVRow]
    var rejectedRowCount: Int
}

enum CursorUsageCSVError: Error, Equatable {
    case missingColumns([String])
    case malformedCSV
}

enum CursorUsageCSV {
    private enum Column {
        static let date = "Date"
        static let model = "Model"
        static let cacheWrite = "Input (w/ Cache Write)"
        static let input = "Input (w/o Cache Write)"
        static let cacheRead = "Cache Read"
        static let output = "Output Tokens"
        static let required = [date, model, cacheWrite, input, cacheRead, output]
    }

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

    /// Pure boundary parser: maps Cursor's exported CSV text into priced rows, rejects malformed rows,
    /// and fails when the export schema itself is unusable. Empty numeric cells are valid zeroes; a
    /// non-empty non-integer or negative token count rejects that row instead of silently becoming zero.
    ///
    /// Cursor's CSV rows are aggregates, not individual requests, so long-context thresholds and Max
    /// Mode uplift cannot be applied reliably from row totals; rows bill at the base model API rate.
    static func parse(csv: String, pricing: ModelPricing) throws -> CursorUsageCSVParseResult {
        var rows: [CursorUsageCSVRow] = []
        var rejectedRowCount = 0
        var acceptedTokenCount = 0
        var missingColumns = Column.required
        var hasDuplicateColumns = false
        let summary = CursorCSVParser.forEachRecord(in: csv, header: { header in
            let available = Set(header)
            missingColumns = Column.required.filter { !available.contains($0) }
            hasDuplicateColumns = available.count != header.count
        }) { r in
            guard let dateStr = r[Column.date]?.trimmingCharacters(in: .whitespaces),
                  !dateStr.isEmpty,
                  let date = parseDate(dateStr),
                  let model = r[Column.model]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty,
                  let cacheWrite = parseIntValue(r[Column.cacheWrite]),
                  let input = parseIntValue(r[Column.input]),
                  let cacheRead = parseIntValue(r[Column.cacheRead]),
                  let output = parseIntValue(r[Column.output]),
                  let rowTokenCount = addingWithoutOverflow([cacheWrite, input, cacheRead, output])
            else {
                rejectedRowCount += 1
                return
            }
            let aggregate = acceptedTokenCount.addingReportingOverflow(rowTokenCount)
            guard !aggregate.overflow else {
                rejectedRowCount += 1
                return
            }
            acceptedTokenCount = aggregate.partialValue

            // The CSV's "Input (w/ Cache Write)" tokens were written to the prompt cache; Anthropic
            // bills those at the 5-minute cache-write rate, other providers at the input rate (their
            // pricing entries carry cacheWrite == input).
            let tokens = TokenBreakdown(
                input: input,
                cacheWrite5m: cacheWrite,
                cacheRead: cacheRead,
                output: output
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
        guard summary.isStructurallyComplete, !hasDuplicateColumns else {
            throw CursorUsageCSVError.malformedCSV
        }
        guard missingColumns.isEmpty else { throw CursorUsageCSVError.missingColumns(missingColumns) }
        rejectedRowCount += summary.rejectedRecordCount
        return CursorUsageCSVParseResult(rows: rows, rejectedRowCount: rejectedRowCount)
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let d = isoFractional.date(from: raw) { return d }
        if let d = iso.date(from: raw) { return d }
        return plainDateTime.date(from: raw)
    }

    private static func parseIntValue(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespaces)
        if normalized.isEmpty { return 0 }

        let groups = normalized.split(separator: ",", omittingEmptySubsequences: false)
        if groups.count > 1 {
            guard let first = groups.first,
                  (1...3).contains(first.utf8.count),
                  isASCIIDigits(first),
                  groups.dropFirst().allSatisfy({ $0.utf8.count == 3 && isASCIIDigits($0) })
            else {
                return nil
            }
        } else if !isASCIIDigits(normalized[...]) {
            return nil
        }
        return Int(groups.joined())
    }

    private static func isASCIIDigits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func addingWithoutOverflow(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}
