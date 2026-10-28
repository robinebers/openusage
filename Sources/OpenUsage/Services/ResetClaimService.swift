import Foundation

enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    case unconfirmed
    case unavailableNow(until: Date?)
    case failed(ResetClaimFailure)
}

extension ResetClaimOutcome {
    func message(now: Date = Date()) -> String {
        switch self {
        case .success:
            "Reset claimed. Enjoy!"
        case .nothingToReset:
            "Your usage doesn't need a reset yet"
        case .noCredit:
            "That reset is no longer available"
        case .unconfirmed:
            "Your reset may still be going through. Check again in a minute."
        case .unavailableNow(let until):
            "Resets can't be used right now." + (until.flatMap { Formatters.whenLabel(at: $0, mode: .relative, now: now) }
                .map { $0 == Formatters.imminent ? " Try again soon." : " Try again in \($0)." } ?? "")
        case .failed(.signInExpired):
            "Your sign-in expired. Remove the account and add it again."
        case .failed(.notPermitted):
            "This sign-in can't use resets. Use the reset in Claude Code instead."
        case .failed(.connection):
            "Couldn't connect. Check your internet connection and try again."
        case .failed(.refused):
            "Couldn't reset usage. Please try again."
        }
    }
}

enum ResetClaimFailure: Equatable, Sendable {
    case signInExpired
    case notPermitted
    case connection
    case refused

    init(_ error: Error) {
        switch error {
        case ProviderError.signInExpired:
            self = .signInExpired
        case is URLError, ProviderError.connectionFailed:
            self = .connection
        default:
            self = .refused
        }
    }
}

@MainActor
struct ResetClaimService {
    let accountID: String
    let isClaimable: Bool
    let confirmDetail: String?
    let claimReset: @MainActor (_ expiry: Date, _ redeemRequestID: String) async -> ResetClaimOutcome
    let refreshAccount: @MainActor () async -> WidgetDataStore.RefreshOutcome
    let refreshDelay: Duration
    var pause: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// The claim's result shows first; the refresh that drops the spent row follows after the delay.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        let outcome = await claimReset(expiry, redeemRequestID)
        if case .failed = outcome { return outcome }
        Task {
            await pause(refreshDelay)
            await refreshAfterClaim()
        }
        return outcome
    }

    private func refreshAfterClaim() async {
        let outcome = await refreshAccount()
        guard outcome != .refreshed, outcome != .cacheHit else { return }
        AppLog.warn(.refresh, "\(accountID) post-claim refresh \(outcome); meters may lag until the next pass")
    }
}
