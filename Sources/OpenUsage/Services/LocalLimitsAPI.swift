import Foundation

/// Machine-facing limits serializer shared by the one-shot CLI and local HTTP API.
/// Provider refresh/mapping remains the single source of truth; this edge only selects scalar resources
/// explicitly declared on `WidgetDescriptor` and gives them stable public names.
enum LocalLimitsAPI {
    static let schema = "openusage.limits.v1"

    static func encode(providerIDs: [String], state: LocalUsageAPI.State) -> Data {
        var providers: [String: WireProvider] = [:]
        for providerID in providerIDs {
            guard let snapshot = state.snapshots[providerID] else { continue }
            let descriptors = state.limitDescriptors[providerID] ?? []
            providers[providerID] = WireProvider(
                snapshot: snapshot,
                descriptors: descriptors,
                generatedAt: state.generatedAt
            )
        }
        let errors = providerIDs.compactMap { providerID in
            state.errors[providerID].map { WireError(providerID: providerID, message: $0) }
        }
        return encode(WireEnvelope(
            schema: schema,
            generatedAt: OpenUsageISO8601.string(from: state.generatedAt),
            providers: providers,
            errors: errors
        ))
    }

    private static func encode(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data(#"{"errors":[],"providers":{},"schema":"openusage.limits.v1"}"#.utf8)
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
        var estimated: Bool?

        init?(resource: LimitResourceDescriptor, line: MetricLine) {
            kind = resource.kind
            unit = Self.progressUnit(line) ?? resource.unit

            switch (resource.source, line) {
            case (.progress, .progress(_, let rawUsed, let rawLimit, _, let reset, let periodMs, _)):
                applyProgress(
                    used: rawUsed, limit: rawLimit, reset: reset, periodMs: periodMs,
                    resource: resource
                )

            case (.progressOrValue(_, _),
                  .progress(_, let rawUsed, let rawLimit, _, let reset, let periodMs, _)):
                applyProgress(
                    used: rawUsed, limit: rawLimit, reset: reset, periodMs: periodMs,
                    resource: resource
                )

            case (.value(let expectedKind, let expectedLabel),
                  .values(_, let values, _, let expiries, _, _)),
                 (.progressOrValue(let expectedKind, let expectedLabel),
                  .values(_, let values, _, let expiries, _, _)):
                guard let metric = values.first(where: { value in
                    value.kind == expectedKind && (expectedLabel == nil || value.label == expectedLabel)
                }) else { return nil }
                if resource.kind == .balance {
                    available = metric.number
                } else {
                    used = metric.number
                }
                expiresAt = expiries.isEmpty ? nil : expiries.sorted().map(OpenUsageISO8601.string(from:))
                estimated = resource.estimated || metric.estimated ? true : nil

            default:
                return nil
            }
        }

        /// A descriptor names the stable resource and supplies a fallback unit for value rows. Progress
        /// rows carry their actual runtime unit, which can vary by plan (for example Cursor Total Usage
        /// is percent on individual plans and requests on request-based Enterprise plans).
        private static func progressUnit(_ line: MetricLine) -> String? {
            guard case .progress(_, _, _, let format, _, _, _) = line else { return nil }
            switch format {
            case .percent:
                return "percent"
            case .dollars:
                return "usd"
            case .count(let suffix):
                return suffix.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
        }

        private mutating func applyProgress(
            used rawUsed: Double,
            limit rawLimit: Double,
            reset: Date?,
            periodMs: Int?,
            resource: LimitResourceDescriptor
        ) {
            let boundedLimit = max(0, rawLimit)
            let boundedUsed = max(0, rawUsed)
            used = resource.kind == .consumption ? boundedUsed : nil
            available = resource.kind == .balance ? boundedUsed : nil
            limit = boundedLimit
            remaining = max(0, boundedLimit - boundedUsed)
            utilization = boundedLimit > 0 ? boundedUsed / boundedLimit : nil
            resetsAt = reset.map(OpenUsageISO8601.string(from:))
            windowSeconds = periodMs.map { Double($0) / 1_000 }
            estimated = resource.estimated ? true : nil
        }
    }
}
