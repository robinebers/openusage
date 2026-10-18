import Foundation
import SwiftUI

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
    case failed
}

/// Claims one rate-limit reset from the resets popover. Never throws: every failure is logged and
/// collapsed to an outcome.
@MainActor
protocol ResetClaimService: AnyObject, Sendable {
    /// `false` renders the timeline read-only (no "Use").
    var isClaimable: Bool { get }
    /// Replaces the confirm card's default explanation line.
    var confirmDetail: String? { get }
    func claim(creditExpiringAt expiry: Date, redeemRequestID: String) async -> ResetClaimOutcome
}

extension ResetClaimService {
    var isClaimable: Bool { true }
    var confirmDetail: String? { nil }
}

/// The post-claim forced refresh both providers share. The forced refresh returns `.skipped` when
/// another refresh already owns the provider — and that in-flight probe may carry *pre-claim* usage —
/// so retry until this refresh actually runs. The bound must outlast the provider's slowest refresh
/// (≈45s of chained timeouts); a `.failed` probe is retried a few times so a transient flake can't
/// strand pre-claim meters behind a success banner, then gives up loudly.
@MainActor
enum ResetClaimRefresh {
    static func run(dataStore: WidgetDataStore?, providerID: String, tag: String) async {
        var failures = 0
        for attempt in 0..<45 {
            guard let dataStore else { return }
            switch await dataStore.refresh(providerID: providerID, force: true) {
            case .refreshed, .cacheHit, .backedOff:
                return
            case .failed:
                failures += 1
                guard failures < 3 else {
                    AppLog.error(LogTag.plugin(tag), "post-claim refresh failed \(failures) times; meters may lag until the next cycle")
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            case .skipped:
                AppLog.info(LogTag.plugin(tag), "post-claim refresh waiting out an in-flight refresh (attempt \(attempt + 1))")
                try? await Task.sleep(for: .seconds(1))
            }
        }
        AppLog.error(LogTag.plugin(tag), "post-claim refresh kept being skipped; meters may lag until the next cycle")
    }
}

/// Hands the claim services to the resets popover through the environment: `nil` (the default —
/// previews, share-card renders, reorder previews) renders the timeline read-only.
private struct ResetClaimServiceKey: EnvironmentKey {
    static let defaultValue: (any ResetClaimService)? = nil
}

private struct ResetClaimsKey: EnvironmentKey {
    static let defaultValue: [String: any ResetClaimService] = [:]
}

extension EnvironmentValues {
    var resetClaims: [String: any ResetClaimService] {
        get { self[ResetClaimsKey.self] }
        set { self[ResetClaimsKey.self] = newValue }
    }

    var resetClaim: (any ResetClaimService)? {
        get { self[ResetClaimServiceKey.self] }
        set { self[ResetClaimServiceKey.self] = newValue }
    }
}
