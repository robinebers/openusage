import Foundation

struct SecondaryRead<Value> {
    private(set) var value: Value?
    private var readAt: Date?

    func isDue(at now: Date) -> Bool {
        guard let readAt else { return true }
        return now.timeIntervalSince(readAt) >= RefreshSetting.secondaryReadInterval
    }

    mutating func record(_ fresh: Value?, at now: Date) {
        readAt = now
        if let fresh { value = fresh }
    }

    mutating func forget() {
        readAt = nil
    }
}
