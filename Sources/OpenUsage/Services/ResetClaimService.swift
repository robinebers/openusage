import Foundation

enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    case unconfirmed
    case unavailableNow(until: Date?)
    /// Claude refused this reset because another one has to be used first (`not_next_grant`).
    case notNextReset(next: ResetKind?)
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
        case .notNextReset(let next):
            "Claude wants \(next.map { "your \($0.title)" } ?? "another reset") used first. Nothing was used."
        case .failed(.signInExpired):
            "Your sign-in expired. Sign in again from the account's page."
        case .failed(.notPermitted):
            "This sign-in can't use resets. Remove the account and add it again."
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
        case is URLError, ProviderError.connectionFailed, ProviderError.unreachable, ProviderError.offline:
            self = .connection
        default:
            self = .refused
        }
    }
}

/// What a reset refills, read from the provider's own fields. Ties at one expiry list in this order.
enum ResetKind: Int, Sendable {
    case session, weekly, fable, full

    var title: String {
        switch self {
        case .session: "Session Reset"
        case .weekly: "Weekly Reset"
        case .fable: "Fable Reset"
        case .full: "Full Reset"
        }
    }
}

/// The record a claim spends: Claude's grant, ChatGPT's credit with that expiry, or Z.ai's exact record.
enum ResetClaimRef: Hashable, Sendable {
    case claudeGrant(String)
    case codexCredit(Date)
    case zai(ZAIReset)

    /// Orders two resets that share an expiry and a kind, so the list keeps its order across refreshes.
    fileprivate var tieBreaker: (record: Int, grant: String) {
        switch self {
        case .claudeGrant(let id): (0, id)
        case .codexCredit: (0, "")
        case .zai(let reset): (reset.recordID, "")
        }
    }
}

/// One reset on the Limit Resets timeline: one row each, for every provider.
struct ResetItem: Hashable, Sendable {
    let kind: ResetKind
    let expiresAt: Date
    let claim: ResetClaimRef
    /// Whether the row offers Use.
    var usable = true
    /// The confirmation's sentence; nil keeps the general wording.
    var confirmDetail: String?

    static func timelineOrder(_ lhs: ResetItem, _ rhs: ResetItem) -> Bool {
        let (left, right) = (lhs.claim.tieBreaker, rhs.claim.tieBreaker)
        return (lhs.expiresAt, lhs.kind.rawValue, left.record, left.grant) < (rhs.expiresAt, rhs.kind.rawValue, right.record, right.grant)
    }
}

@MainActor
struct ResetClaimService {
    let accountID: String
    /// Every reset the account holds, one row each; empty until the provider's list is read.
    let items: [ResetItem]
    let claimReset: @MainActor (_ claim: ResetClaimRef, _ requestID: String) async -> ResetClaimOutcome
    let refreshAccount: @MainActor () async -> WidgetDataStore.RefreshOutcome

    /// Spends exactly the reset on the chosen row. The claim's result shows first; the refresh that drops
    /// the spent row starts at once behind it.
    func claim(_ item: ResetItem, requestID: String) async -> ResetClaimOutcome {
        let outcome = await claimReset(item.claim, requestID)
        if case .failed = outcome { return outcome }
        Task { await refreshAfterClaim() }
        return outcome
    }

    private func refreshAfterClaim() async {
        let outcome = await refreshAccount()
        guard outcome != .refreshed, outcome != .cacheHit else { return }
        AppLog.warn(.refresh, "\(accountID) post-claim refresh \(outcome); meters may lag until the next pass")
    }
}
