import Foundation

/// A read that changes far less often than usage (a plan name, Codex's reset-credit list), asked at most
/// once per `RefreshSetting.secondaryReadInterval` while usage is asked every pass. A failed read keeps
/// the last answer and still counts as the interval's read, so a broken endpoint costs one request an
/// hour instead of one per pass.
struct SecondaryRead<Value> {
    private(set) var value: Value?
    private var readAt: Date?

    func isDue(at now: Date) -> Bool {
        guard let readAt else { return true }
        return now.timeIntervalSince(readAt) >= RefreshSetting.secondaryReadInterval
    }

    /// Records a read at `now`: its answer, or the last one when it failed (`nil`).
    mutating func record(_ fresh: Value?, at now: Date) {
        readAt = now
        if let fresh { value = fresh }
    }

    /// Makes the next refresh read again, after something (a claim, a forced refresh) changed or may have
    /// changed the answer.
    mutating func forget() {
        readAt = nil
    }
}
