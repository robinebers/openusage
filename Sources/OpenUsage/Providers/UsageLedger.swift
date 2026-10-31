import Foundation

protocol UsageHistorySource: Sendable {
    /// The calendar whose days the provider reports.
    var calendar: Calendar { get }
    /// How long today and yesterday wait after a read before they are read again.
    var rereadInterval: TimeInterval { get }
    /// The days read in full, keyed by day start. A day that could not be read is left out.
    /// Today's read ends at `asOf`. `rateLimitedFor` is how long to wait when the provider rate-limited the read.
    func read(_ days: [Date], asOf: Date, calendar: Calendar) async -> (days: [Date: UsageDay], rateLimitedFor: TimeInterval?)
}

extension UsageHistorySource {
    var calendar: Calendar { .current }
    var rereadInterval: TimeInterval { 0 }
}

/// An account's read days, in memory only. Its source is its only writer.
struct UsageLedger: Sendable {
    private(set) var days: [Date: UsageDay] = [:]
    /// Nothing is read before this once the provider rate-limited a read.
    private var resumeAt: Date?
    /// Today at the last record, whose read ended before the day did.
    private var partialDay: Date?
    /// When the last read was sent; ⌘R clears it.
    var readAt: Date?

    /// True while today's last read is younger than `interval`; a new day ends the wait at once.
    func isResting(_ span: [Date], at now: Date, every interval: TimeInterval) -> Bool {
        guard let readAt, span.first == partialDay else { return false }
        return now.timeIntervalSince(readAt) < interval
    }

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

    func isHeld(at now: Date) -> Bool { resumeAt.map { now < $0 } ?? false }

    mutating func hold(for wait: TimeInterval, from now: Date) { resumeAt = now.addingTimeInterval(wait) }
}

extension AccountProviderRuntime {
    /// Reads the due days and returns every read day. Never throws, so history cannot fail the card.
    func refreshHistory(using source: some UsageHistorySource) async -> UsageHistory? {
        guard let dayCount = HistoryRow.dayCount(for: widgetDescriptors) else { return nil }
        let calendar = source.calendar
        let asOf = now()
        let span = UsageHistory.dayStarts(0..<dayCount, now: asOf, calendar: calendar)
        let due = usageLedger.isResting(span, at: asOf, every: source.rereadInterval) ? [] : usageLedger.due(span)
        if due.isEmpty || usageLedger.isHeld(at: asOf) {
            usageLedger.record([:], due: due, span: span)
        } else {
            usageLedger.readAt = asOf
            let read = await source.read(due, asOf: asOf, calendar: calendar)
            usageLedger.record(read.days, due: due, span: span)
            if let wait = read.rateLimitedFor { usageLedger.hold(for: wait, from: now()) }
        }
        return UsageHistory(calendar: calendar, asOf: asOf, days: usageLedger.days)
    }
}
