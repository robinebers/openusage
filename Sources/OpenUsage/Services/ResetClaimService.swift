import Foundation

/// The outcome of a rate-limit reset claim, as the resets popover renders it. Each provider collapses
/// its own protocol answers into these.
enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    /// The server took the claim but couldn't confirm it landed (Claude only).
    case unconfirmed
    /// A reset exists but can't be used right now, e.g. a cooldown (Claude only).
    case unavailableNow(until: Date?)
    /// The claim didn't go through, or its answer never came back.
    case failed(ResetClaimFailure)
}

extension ResetClaimOutcome {
    /// What the resets popover's banner says once a claim resolves. A failure says what the user can
    /// do about it.
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
            "Your sign-in expired. Add the account again."
        case .failed(.notPermitted):
            "This sign-in can't use resets. Use the reset in Claude Code instead."
        case .failed(.connection):
            "Couldn't connect. Check your internet connection and try again."
        case .failed(.refused):
            "Couldn't reset usage. Please try again."
        }
    }
}

/// Why a claim failed, so the popover can tell the user what to do about it.
enum ResetClaimFailure: Equatable, Sendable {
    /// The account's sign-in no longer works; adding the account again fixes it.
    case signInExpired
    /// The provider turned the claim down because the sign-in's scopes don't cover it (Claude only).
    /// Adding the account again asks for the same scopes, so the advice points elsewhere.
    case notPermitted
    /// The request never reached the provider, or its answer never came back.
    case connection
    /// The provider refused the claim or answered with something the app can't read.
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

/// The resets popover's claim seam for one account: the runtime's claim plus a forced refresh of that
/// account, so the result banner appears over already-reconciled meters. Built fresh from the live
/// runtime each time the dashboard renders, so `isClaimable` and `confirmDetail` follow its latest data.
@MainActor
struct ResetClaimService {
    let accountID: String
    /// `false` renders the timeline read-only (no "Use").
    let isClaimable: Bool
    /// Replaces the confirm card's default explanation line.
    let confirmDetail: String?
    let claimReset: @MainActor (_ expiry: Date, _ redeemRequestID: String) async -> ResetClaimOutcome
    let refreshAccount: @MainActor () async -> WidgetDataStore.RefreshOutcome
    /// How long after a claim the account is refreshed. Codex refreshes at once, so the banner lands over
    /// meters that already show the claim. Claude's answer already updated its resets row, so its meters
    /// are read in the background 30 seconds later, apart from the claim.
    var refreshDelay: Duration = .zero
    var pause: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// Claims the reset the popover picked, then refreshes the account unless nothing was claimed.
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome {
        let outcome = await claimReset(expiry, redeemRequestID)
        if case .failed = outcome { return outcome }
        guard refreshDelay > .zero else {
            await refreshAfterClaim()
            return outcome
        }
        Task {
            await pause(refreshDelay)
            await refreshAfterClaim()
        }
        return outcome
    }

    /// One forced refresh. One that another refresh or a wait the provider set holds off, or that fails,
    /// leaves the meters to the next pass.
    private func refreshAfterClaim() async {
        let outcome = await refreshAccount()
        guard outcome != .refreshed, outcome != .cacheHit else { return }
        AppLog.warn(.refresh, "\(accountID) post-claim refresh \(outcome); meters may lag until the next pass")
    }
}
