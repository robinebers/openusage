import Foundation

protocol UsageHistorySource: Sendable {
    /// The days read in full, keyed by day start. A day that could not be read is left out.
    /// Today's read ends at `asOf`.
    func read(_ days: [Date], asOf: Date, calendar: Calendar) async -> [Date: UsageDay]
}

/// An account's read days, in memory only. Its source is its only writer.
struct UsageLedger: Sendable {
    private(set) var days: [Date: UsageDay] = [:]
    /// Today at the last record, whose read ended before the day did.
    private var partialDay: Date?

    /// `span` runs back from today. Today and yesterday are read on every refresh, an older day until one
    /// read of it after its end succeeds.
    func due(_ span: [Date]) -> [Date] {
        Array(span.prefix(2)) + span.dropFirst(2).filter { days[$0] == nil || $0 == partialDay }
    }

    /// Days outside `span` are dropped, and a due day that did not come back is unread, so a failed re-read
    /// hides its rows instead of showing an old value.
    mutating func record(_ read: [Date: UsageDay], due: [Date], span: [Date]) {
        let kept = Set(span).subtracting(due)
        days = days.filter { kept.contains($0.key) }.merging(read) { _, new in new }
        partialDay = span.first
    }
}

extension AccountProviderRuntime {
    /// Reads the due days and returns every read day. Never throws, so history cannot fail the card.
    func refreshHistory(using source: some UsageHistorySource) async -> UsageHistory? {
        guard let dayCount = HistoryRow.dayCount(for: widgetDescriptors) else { return nil }
        let calendar = Calendar.current
        let asOf = now()
        let span = UsageHistory.dayStarts(0..<dayCount, now: asOf, calendar: calendar)
        let due = usageLedger.due(span)
        let read = await source.read(due, asOf: asOf, calendar: calendar)
        usageLedger.record(read, due: due, span: span)
        return UsageHistory(calendar: calendar, asOf: asOf, days: usageLedger.days)
    }
}
