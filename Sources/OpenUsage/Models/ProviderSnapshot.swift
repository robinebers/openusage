import Foundation

struct ProviderSnapshot: Hashable, Sendable, Codable {
    let providerID: String
    let displayName: String
    var plan: String?
    var lines: [MetricLine]
    var refreshedAt: Date
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

    init(provider: Provider, plan: String?, lines: [MetricLine], refreshedAt: Date = Date()) {
        self.init(providerID: provider.id, displayName: provider.displayName, plan: plan, lines: lines, refreshedAt: refreshedAt)
    }

    init(provider: Provider, failure: RefreshFailure) {
        self.init(providerID: provider.id, displayName: provider.displayName, lines: [], failure: failure)
    }
}

struct RefreshFailure: Hashable, Sendable, Codable {
    enum Kind: Hashable, Sendable, Codable {
        case rateLimited(retryAfter: TimeInterval?)
        case unreachable
        case refused
    }

    var message: String
    var kind: Kind
}

extension RefreshFailure {
    init(error: Error) {
        let kind: Kind = switch error {
        case ProviderError.rateLimited(let retryAfter): .rateLimited(retryAfter: retryAfter)
        case is URLError, ProviderError.connectionFailed: .unreachable
        default: .refused
        }
        self.init(message: error.localizedDescription, kind: kind)
    }
}
