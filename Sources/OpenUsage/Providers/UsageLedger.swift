import Foundation

protocol UsageHistorySource: Sendable {
    /// The calendar whose days the provider reports.
    var calendar: Calendar { get }
    /// How long today and yesterday stay read; nil rereads them on every refresh.
    var rereadInterval: TimeInterval? { get }
    /// The days read in full, keyed by day start. A day that could not be read is left out.
    /// Today's read ends at `asOf`. `rateLimitedFor` is how long to wait when the provider rate-limited the read.
    func read(_ days: [Date], asOf: Date, calendar: Calendar) async -> (days: [Date: UsageDay], rateLimitedFor: TimeInterval?)
}

extension UsageHistorySource {
    var calendar: Calendar { .current }
    var rereadInterval: TimeInterval? { nil }
}

/// An account's read days, in memory only. Its source is its only writer.
@MainActor
final class UsageLedger {
    private(set) var days: [Date: UsageDay] = [:]
    /// Nothing is read before this once the provider rate-limited a read.
    private var resumeAt: Date?
    /// Today at the last record, whose read ended before the day did.
    private var partialDay: Date?
    /// When the last read was sent, and the day that was today then.
    private var lastRead: (at: Date, today: Date)?

    /// `span` runs back from today. Today and yesterday are read on every refresh, an older day until one
    /// read of it after its end succeeds.
    func due(_ span: [Date]) -> [Date] {
        Array(span.prefix(2)) + span.dropFirst(2).filter { days[$0] == nil || $0 == partialDay }
    }

    /// Days outside `span` are dropped, and a due day that did not come back is unread, so a failed re-read
    /// hides its rows instead of showing an old value.
    func record(_ read: [Date: UsageDay], due: [Date], span: [Date]) {
        let kept = Set(span).subtracting(due)
        days = days.filter { kept.contains($0.key) }.merging(read) { _, new in new }
        partialDay = span.first
    }

    func isHeld(at now: Date) -> Bool { resumeAt.map { now < $0 } ?? false }

    func hold(for wait: TimeInterval, from now: Date) { resumeAt = now.addingTimeInterval(wait) }

    /// Whether nothing is due for a source that rereads once per `interval`: the last read was sent on this
    /// same day, less than `interval` ago. A new day is read at once.
    func isResting(_ span: [Date], at now: Date, interval: TimeInterval) -> Bool {
        guard let lastRead, lastRead.today == span.first else { return false }
        return now < lastRead.at.addingTimeInterval(interval)
    }

    func noteRead(at now: Date, today: Date) { lastRead = (now, today) }

    /// A forced refresh reads today and yesterday again at once.
    func forgetLastRead() { lastRead = nil }
}

extension AccountProviderRuntime {
    /// Reads the due days and returns every read day. Never throws, so history cannot fail the card.
    func refreshHistory(using source: some UsageHistorySource, ledger: UsageLedger? = nil) async -> UsageHistory? {
        let ledger = ledger ?? usageLedger
        guard let dayCount = HistoryRow.dayCount(for: widgetDescriptors) else { return nil }
        let calendar = source.calendar
        let asOf = now()
        let span = UsageHistory.dayStarts(0..<dayCount, now: asOf, calendar: calendar)
        if let interval = source.rereadInterval, ledger.isResting(span, at: asOf, interval: interval) {
            return UsageHistory(calendar: calendar, asOf: asOf, days: ledger.days)
        }
        let due = ledger.due(span)
        if ledger.isHeld(at: asOf) {
            ledger.record([:], due: due, span: span)
        } else {
            ledger.noteRead(at: asOf, today: span[0])
            let read = await source.read(due, asOf: asOf, calendar: calendar)
            ledger.record(read.days, due: due, span: span)
            if let wait = read.rateLimitedFor { ledger.hold(for: wait, from: now()) }
        }
        return UsageHistory(calendar: calendar, asOf: asOf, days: ledger.days)
    }
}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
