import Foundation

/// Routing + JSON for the read-only local usage API, kept pure so it's unit-testable —
/// `LocalUsageServer` is just the transport. The wire format matches the original app's
/// docs/local-http-api.md exactly (camelCase `providerId`, `color`, `fetchedAt`, type-tagged
/// `lines`, `{"error": code}` bodies) so existing third-party consumers keep working unchanged.
enum LocalUsageAPI {
    /// Everything one request needs, captured from the MainActor stores into a Sendable value.
    struct State: Sendable {
        /// Provider IDs the collection endpoint serves: enablement-filtered, in the user's order.
        var enabledOrderedIDs: [String]
        /// Every provider the registry knows — single-provider lookups work for disabled ones too.
        var knownIDs: Set<String>
        var snapshots: [String: ProviderSnapshot]
    }

    struct Response: Equatable, Sendable {
        var status: Int
        var body: Data?
    }

    static func respond(method: String, path: String, state: State) -> Response {
        // Preflight support: OPTIONS anywhere is 204 + the CORS headers the server always sends.
        if method == "OPTIONS" {
            return Response(status: 204, body: nil)
        }

        let segments = path.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "/")
            .map(String.init)

        switch (segments.count, segments.first, segments.dropFirst().first) {
        case (2, "v1", "usage"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            let snapshots = state.enabledOrderedIDs.compactMap { state.snapshots[$0] }
            return Response(status: 200, body: encode(snapshots.map(WireSnapshot.init)))

        case (3, "v1", "usage"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            let providerID = segments[2]
            guard state.knownIDs.contains(providerID) else { return error(404, "provider_not_found") }
            guard let snapshot = state.snapshots[providerID] else { return Response(status: 204, body: nil) }
            return Response(status: 200, body: encode(WireSnapshot(snapshot)))

        default:
            return error(404, "not_found")
        }
    }

    static let busy = error(503, "server_busy")

    private static func error(_ status: Int, _ code: String) -> Response {
        Response(status: status, body: Data(#"{"error":"\#(code)"}"#.utf8))
    }

    private static func encode(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
    }

    // MARK: - Wire types (the documented public shape, distinct from the internal cache Codable)

    private struct WireSnapshot: Encodable {
        let snapshot: ProviderSnapshot

        init(_ snapshot: ProviderSnapshot) { self.snapshot = snapshot }

        enum CodingKeys: String, CodingKey {
            case providerId, displayName, plan, lines, fetchedAt
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(snapshot.providerID, forKey: .providerId)
            try container.encode(snapshot.displayName, forKey: .displayName)
            try container.encode(snapshot.plan, forKey: .plan)
            try container.encode(snapshot.lines.map(WireLine.init), forKey: .lines)
            try container.encode(OpenUsageISO8601.string(from: snapshot.refreshedAt), forKey: .fetchedAt)
        }
    }

    private struct WireLine: Encodable {
        let line: MetricLine

        init(_ line: MetricLine) { self.line = line }

        enum CodingKeys: String, CodingKey {
            case type, label, value, used, limit, format, resetsAt, periodDurationMs, color, subtitle, text, points, note
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch line {
            case .text(let label, let value, let color, let subtitle):
                try container.encode("text", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(value, forKey: .value)
                try container.encode(color, forKey: .color)        // explicit null, like the original
                try container.encode(subtitle, forKey: .subtitle)
            case .values(let label, let values, let color, let expiriesAt, _, _):
                // Serialize as the original `text` shape (one combined `value` string) so existing
                // local-API integrations keep working: dollars in full, counts compact — exactly the
                // string the mapper used to produce (e.g. "$5.17 · 9.2M tokens").
                // Per-model hover details are UI-only for now and are intentionally omitted from this
                // documented public wire shape.
                try container.encode("text", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(Self.legacyValueString(values), forKey: .value)
                try container.encode(color, forKey: .color)
                try container.encodeNil(forKey: .subtitle)
                // Expose the soonest expiry (Codex reset credits) as ISO-8601 so consumers get the next
                // one without us baking a display string — same `resetsAt` field a progress row uses.
                try container.encodeIfPresent(expiriesAt.min().map(OpenUsageISO8601.string(from:)), forKey: .resetsAt)
            case .progress(let label, let used, let limit, let format, let resetsAt, let periodDurationMs, let color):
                try container.encode("progress", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(used, forKey: .used)
                try container.encode(limit, forKey: .limit)
                try container.encode(format, forKey: .format)      // {"kind": ...} (+ "suffix" for counts)
                try container.encodeIfPresent(resetsAt.map(OpenUsageISO8601.string(from:)), forKey: .resetsAt)
                try container.encodeIfPresent(periodDurationMs, forKey: .periodDurationMs)
                try container.encode(color, forKey: .color)
            case .badge(let label, let text, let color, let subtitle):
                try container.encode("badge", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(text, forKey: .text)
                try container.encode(color, forKey: .color)
                try container.encode(subtitle, forKey: .subtitle)
            case .chart(let label, let points, let note):
                // The original app's `barChart` line shape: per-day {label, value, valueLabel} points
                // plus an optional source note, so existing local-API integrations read the trend too.
                try container.encode("barChart", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(points, forKey: .points)
                try container.encodeIfPresent(note, forKey: .note)
                try container.encodeNil(forKey: .color)
            }
        }

        /// The legacy combined string for a `.values` row: each value formatted (dollars full so cents
        /// survive, counts compact like the mapper's old `formatTokens`) and joined with " · ".
        private static func legacyValueString(_ values: [MetricValue]) -> String {
            values
                .map { MetricFormatter.string(for: $0, style: $0.kind == .count ? .tray : .full) }
                .joined(separator: " · ")
        }
    }
}
