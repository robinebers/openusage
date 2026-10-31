import Foundation

enum LimitsEnvelope {
    static let schema = "openusage.limits.v2"

    struct Input: Sendable {
        var registry: WidgetRegistry
        var snapshots: [String: ProviderSnapshot]
        var generatedAt = Date()
    }

    static func encode(_ input: Input) -> Data {
        var providers: [String: WireProvider] = [:]
        for provider in input.registry.providers {
            guard let snapshot = input.snapshots[provider.id] else { continue }
            providers[provider.id] = WireProvider(
                provider: provider,
                snapshot: snapshot,
                descriptors: input.registry.descriptors(for: provider.id),
                generatedAt: input.generatedAt
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelope = WireEnvelope(
            schema: schema,
            generatedAt: OpenUsageISO8601.string(from: input.generatedAt),
            providers: providers
        )
        return (try? encoder.encode(envelope))
            ?? Data(#"{"providers":{},"schema":"\#(schema)"}"#.utf8)
    }

    private struct WireEnvelope: Encodable {
        let schema: String
        let generatedAt: String
        let providers: [String: WireProvider]
    }

    private struct WireProvider: Encodable {
        let displayName: String
        let plan: String?
        let fetchedAt: String
        let expiresAt: String
        let stale: Bool
        let resources: [String: WireResource]

        init(provider: Provider, snapshot: ProviderSnapshot, descriptors: [WidgetDescriptor], generatedAt: Date) {
            displayName = provider.fullName
            plan = snapshot.plan
            fetchedAt = OpenUsageISO8601.string(from: snapshot.refreshedAt)
            expiresAt = OpenUsageISO8601.string(from: snapshot.staleAt)
            stale = snapshot.isStale(at: generatedAt)

            var resources: [String: WireResource] = [:]
            for descriptor in descriptors {
                guard let line = snapshot.line(label: descriptor.metricLabel) else { continue }
                for resource in descriptor.limitResources {
                    if let value = WireResource(resource: resource, line: line) {
                        resources[resource.key] = value
                    }
                }
            }
            self.resources = resources
        }
    }

    private struct WireResource: Encodable {
        let kind: LimitResourceDescriptor.Kind
        let unit: String
        var used: Double?
        var available: Double?
        var limit: Double?
        var remaining: Double?
        var utilization: Double?
        var resetsAt: String?
        var windowSeconds: Double?
        var expiresAt: [String]?

        init?(resource: LimitResourceDescriptor, line: MetricLine) {
            kind = resource.kind
            unit = Self.progressUnit(line) ?? resource.unit

            switch (resource.source, line) {
            case (.progress, .progress(_, let rawUsed, let rawLimit, _, let reset, let periodMs)),
                 (.progressOrValue, .progress(_, let rawUsed, let rawLimit, _, let reset, let periodMs)):
                let boundedLimit = max(0, rawLimit)
                let boundedUsed = max(0, rawUsed)
                used = resource.kind == .consumption ? boundedUsed : nil
                available = resource.kind == .balance ? boundedUsed : nil
                limit = boundedLimit
                remaining = max(0, boundedLimit - boundedUsed)
                utilization = boundedLimit > 0 ? boundedUsed / boundedLimit : nil
                resetsAt = reset.map(OpenUsageISO8601.string(from:))
                windowSeconds = periodMs.map { Double($0) / 1_000 }

            case (.value(let expectedKind, let expectedLabel), .values(_, let values, let expiries)),
                 (.progressOrValue(let expectedKind, let expectedLabel), .values(_, let values, let expiries)):
                guard let metric = values.first(where: { value in
                    value.kind == expectedKind && (expectedLabel == nil || value.label == expectedLabel)
                }) else { return nil }
                if resource.kind == .balance {
                    available = metric.number
                } else {
                    used = metric.number
                }
                expiresAt = expiries.isEmpty ? nil : expiries.sorted().map(OpenUsageISO8601.string(from:))

            default:
                return nil
            }
        }

        private static func progressUnit(_ line: MetricLine) -> String? {
            guard case .progress(_, _, _, let format, _, _) = line else { return nil }
            switch format {
            case .percent:
                return "percent"
            case .dollars:
                return "usd"
            case .count(let suffix):
                let unit = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                return unit.isEmpty ? nil : unit
            }
        }
    }
}
