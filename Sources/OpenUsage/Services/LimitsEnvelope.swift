import Foundation

/// The machine-facing limits JSON the `openusage` command prints (schema `openusage.limits.v1`): one
/// entry per account keyed by card id, holding only the scalar resources its descriptors declare
/// through `exportingLimit`. Provider refresh and mapping stay the single source of truth; this edge
/// selects the declared scalars and gives them stable public names.
enum LimitsEnvelope {
    static let schema = "openusage.limits.v1"

    /// Everything one envelope needs, captured from the stores into a value.
    struct Input: Sendable {
        /// The account cards to print, in the user's dashboard order.
        var providerIDs: [String]
        var snapshots: [String: ProviderSnapshot]
        /// Only descriptors that declare at least one limit resource, by card id.
        var limitDescriptors: [String: [WidgetDescriptor]] = [:]
        var errors: [String: String] = [:]
        var generatedAt = Date()
    }

    static func encode(_ input: Input) -> Data {
        var providers: [String: WireProvider] = [:]
        for providerID in input.providerIDs {
            guard let snapshot = input.snapshots[providerID] else { continue }
            providers[providerID] = WireProvider(
                snapshot: snapshot,
                descriptors: input.limitDescriptors[providerID] ?? [],
                generatedAt: input.generatedAt
            )
        }
        let errors = input.providerIDs.compactMap { providerID in
            input.errors[providerID].map { WireError(providerID: providerID, message: $0) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let envelope = WireEnvelope(
            schema: schema,
            generatedAt: OpenUsageISO8601.string(from: input.generatedAt),
            providers: providers,
            errors: errors
        )
        return (try? encoder.encode(envelope))
            ?? Data(#"{"errors":[],"providers":{},"schema":"openusage.limits.v1"}"#.utf8)
    }

    private struct WireEnvelope: Encodable {
        let schema: String
        let generatedAt: String
        let providers: [String: WireProvider]
        let errors: [WireError]
    }

    private struct WireError: Encodable {
        let providerID: String
        let message: String

        enum CodingKeys: String, CodingKey {
            case providerID = "providerId"
            case message
        }
    }

    private struct WireProvider: Encodable {
        let displayName: String
        let plan: String?
        let fetchedAt: String
        let expiresAt: String
        let stale: Bool
        let resources: [String: WireResource]

        init(snapshot: ProviderSnapshot, descriptors: [WidgetDescriptor], generatedAt: Date) {
            displayName = snapshot.displayName
            plan = snapshot.plan
            fetchedAt = OpenUsageISO8601.string(from: snapshot.refreshedAt)
            let expiry = snapshot.refreshedAt.addingTimeInterval(RefreshSetting.interval)
            expiresAt = OpenUsageISO8601.string(from: expiry)
            stale = generatedAt >= expiry

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

        /// A descriptor names the stable resource and supplies a fallback unit for value rows. Progress
        /// rows carry their actual runtime unit, which can vary by plan (Cursor's Total Usage is percent
        /// on individual plans and requests on request-based Enterprise plans).
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
