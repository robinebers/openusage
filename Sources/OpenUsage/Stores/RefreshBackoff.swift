import Foundation

/// How long an account waits after a failed refresh before it is asked again. Each failure in a row
/// doubles the wait, from `RefreshSetting.failureBackoffBase` up to `RefreshSetting.failureBackoffCap`,
/// so an account that keeps failing (a revoked key, a 401 on every pass) drops to one request an hour.
/// A 429 waits exactly as long as its Retry-After says, and on the same doubling when it says nothing.
/// No answer at all (offline) costs the provider nothing, so it retries on the next pass without growing
/// the wait. A success clears the backoff.
struct RefreshBackoff: Equatable {
    /// Failures in a row that grew the wait.
    var failures: Int
    var retryAt: Date
    /// The provider set this wait (HTTP 429), so no refresh, manual or not, asks before `retryAt`.
    var providerAsked: Bool

    /// Whether this wait still stops a refresh at `now`: a forced refresh (⌘R) skips the client's own
    /// backoff, but no refresh asks before a wait the provider set.
    func holds(at now: Date, forced: Bool) -> Bool {
        now < retryAt && (providerAsked || !forced)
    }

    /// The backoff after `failure`, following `previous` (`nil` when the last refresh succeeded).
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

    /// The doubling wait after `failures` failures in a row.
    static func delay(failures: Int) -> TimeInterval {
        let doublings = Double(min(max(failures - 1, 0), 16))
        return min(RefreshSetting.failureBackoffBase * pow(2, doublings), RefreshSetting.failureBackoffCap)
    }
}
