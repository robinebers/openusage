import Foundation

/// Latest normalized output for one provider refresh.
struct ProviderSnapshot: Hashable, Sendable, Codable {
    let providerID: String
    let displayName: String
    var plan: String?
    var lines: [MetricLine]
    var refreshedAt: Date
    /// Set only on a failed refresh: what the card says and how long the store waits before asking
    /// again. `lines` is empty then.
    var failure: RefreshFailure?

    var errorMessage: String? { failure?.message }

    init(
        providerID: String,
        displayName: String,
        plan: String? = nil,
        lines: [MetricLine],
        refreshedAt: Date = Date(),
        failure: RefreshFailure? = nil
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.plan = plan
        self.lines = lines
        self.refreshedAt = refreshedAt
        self.failure = failure
    }

    func line(label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    /// The success-path counterpart to `error(provider:message:)`: derives `providerID`/`displayName`
    /// from the provider so account runtimes build their snapshots consistently.
    static func make(
        provider: Provider,
        plan: String?,
        lines: [MetricLine],
        refreshedAt: Date
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt
        )
    }

    /// Build an error snapshot straight from a caught error: the message is the error's user-facing
    /// `localizedDescription`, and the kind says whether the provider asked for a wait or never answered.
    static func error(provider: Provider, error: Error) -> ProviderSnapshot {
        let kind: RefreshFailure.Kind = switch error {
        case ProviderError.rateLimited(let retryAfter): .rateLimited(retryAfter: retryAfter)
        case is URLError, ProviderError.connectionFailed: .unreachable
        default: .refused
        }
        return Self.error(provider: provider, failure: RefreshFailure(message: error.localizedDescription, kind: kind))
    }

    static func error(provider: Provider, message: String) -> ProviderSnapshot {
        Self.error(provider: provider, failure: RefreshFailure(message: message, kind: .refused))
    }

    static func error(provider: Provider, failure: RefreshFailure) -> ProviderSnapshot {
        ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [], failure: failure)
    }
}

/// Why a refresh failed, in the terms the refresh schedule needs (see `RefreshBackoff`).
struct RefreshFailure: Hashable, Sendable, Codable {
    enum Kind: Hashable, Sendable, Codable {
        /// The provider answered 429. `retryAfter` is the wait it named, if it named one.
        case rateLimited(retryAfter: TimeInterval?)
        /// No answer came back (offline, a dropped connection), so the provider saw nothing.
        case unreachable
        /// The provider answered with an error.
        case refused
    }

    var message: String
    var kind: Kind
}
