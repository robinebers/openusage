import Foundation

struct RefreshBackoff: Equatable {
    var failures: Int
    var retryAt: Date
    var providerAsked: Bool

    func holds(at now: Date, forced: Bool) -> Bool {
        now < retryAt && (providerAsked || !forced)
    }

    static func after(_ failure: RefreshFailure.Kind, previous: RefreshBackoff?, now: Date) -> RefreshBackoff {
        let failures = previous?.failures ?? 0
        switch failure {
        case .unreachable:
            return RefreshBackoff(failures: failures, retryAt: now + RefreshSetting.failureBackoffBase, providerAsked: false)
        case .refused:
            return RefreshBackoff(failures: failures + 1, retryAt: now + delay(failures: failures + 1), providerAsked: false)
        case .rateLimited(let retryAfter):
            let wait = retryAfter ?? delay(failures: failures + 1)
            return RefreshBackoff(failures: failures + 1, retryAt: now + wait, providerAsked: true)
        }
    }

    static func delay(failures: Int) -> TimeInterval {
        let doublings = Double(min(max(failures - 1, 0), 16))
        return min(RefreshSetting.failureBackoffBase * pow(2, doublings), RefreshSetting.failureBackoffCap)
    }
}
