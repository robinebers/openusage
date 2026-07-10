import Foundation

/// JSON DTOs for the shell↔core named-pipe protocol (Phase 3 spike).
/// Newline-delimited JSON; no secrets in any field.
public enum SidecarProtocol {
    public static let version = 1
}

public struct SidecarRequest: Codable, Sendable, Equatable {
    public let op: String
    public let provider: String?

    public init(op: String, provider: String? = nil) {
        self.op = op
        self.provider = provider
    }
}

public struct SidecarResponse: Codable, Sendable, Equatable {
    public let op: String
    public let version: Int?
    public let providers: [SidecarProviderDTO]?
    public let message: String?

    public init(op: String, version: Int? = nil, providers: [SidecarProviderDTO]? = nil, message: String? = nil) {
        self.op = op
        self.version = version
        self.providers = providers
        self.message = message
    }

    public static func pong() -> SidecarResponse {
        SidecarResponse(op: "pong", version: SidecarProtocol.version)
    }

    public static func snapshot(_ providers: [SidecarProviderDTO]) -> SidecarResponse {
        SidecarResponse(op: "snapshot", providers: providers)
    }

    public static func error(_ message: String) -> SidecarResponse {
        SidecarResponse(op: "error", message: message)
    }
}

public struct SidecarProviderDTO: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let plan: String?
    public let credentialsFound: Bool
    public let status: String
    public let metricLines: [SidecarMetricLineDTO]
    public let error: String?
}

public struct SidecarMetricLineDTO: Codable, Sendable, Equatable {
    public let kind: String
    public let label: String
    public let display: String
}

public enum SidecarIPCCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()

    public static func encodeLine<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let line = String(data: data, encoding: .utf8) else {
            throw SidecarIPCError.encodingFailed
        }
        return line
    }

    public static func decodeRequestLine(_ line: String) throws -> SidecarRequest {
        guard let data = line.data(using: .utf8) else {
            throw SidecarIPCError.decodingFailed
        }
        return try decoder.decode(SidecarRequest.self, from: data)
    }

    public static func decodeResponseLine(_ line: String) throws -> SidecarResponse {
        guard let data = line.data(using: .utf8) else {
            throw SidecarIPCError.decodingFailed
        }
        return try decoder.decode(SidecarResponse.self, from: data)
    }
}

public enum SidecarIPCError: Error, Sendable {
    case encodingFailed
    case decodingFailed
    case unknownOperation(String)
}

/// Maps internal provider snapshots into IPC-safe DTOs.
enum SidecarSnapshotMapper {
    static func makeProviderDTO(
        id: String,
        displayName: String,
        credentialsFound: Bool,
        snapshot: ProviderSnapshot?
    ) -> SidecarProviderDTO {
        guard credentialsFound else {
            return SidecarProviderDTO(
                id: id,
                displayName: displayName,
                plan: nil,
                credentialsFound: false,
                status: "no_credentials",
                metricLines: [],
                error: nil
            )
        }

        guard let snapshot else {
            return SidecarProviderDTO(
                id: id,
                displayName: displayName,
                plan: nil,
                credentialsFound: true,
                status: "pending",
                metricLines: [],
                error: nil
            )
        }

        if snapshot.errorCategory != nil || snapshot.lines.contains(where: { $0.isError }) {
            let message = errorMessage(from: snapshot)
            let category = snapshot.errorCategory?.rawValue ?? "other"
            return SidecarProviderDTO(
                id: id,
                displayName: displayName,
                plan: snapshot.plan,
                credentialsFound: true,
                status: "error",
                metricLines: metricLines(from: snapshot.lines),
                error: "\(category): \(message)"
            )
        }

        return SidecarProviderDTO(
            id: id,
            displayName: displayName,
            plan: snapshot.plan,
            credentialsFound: true,
            status: "ok",
            metricLines: metricLines(from: snapshot.lines),
            error: snapshot.warning
        )
    }

    private static func errorMessage(from snapshot: ProviderSnapshot) -> String {
        if case .badge(_, let text, _, _) = snapshot.lines.first(where: { $0.isError }) {
            return text
        }
        return "Refresh failed"
    }

    private static func metricLines(from lines: [MetricLine]) -> [SidecarMetricLineDTO] {
        lines.compactMap { line in
            switch line {
            case .text(let label, let value, _, _):
                return SidecarMetricLineDTO(kind: "text", label: label, display: "\(label): \(value)")
            case .badge(let label, let text, _, _):
                return SidecarMetricLineDTO(kind: "badge", label: label, display: "\(label): \(text)")
            case .progress(let label, let used, let limit, let format, _, _, _):
                let usedText = formatNumber(used, format: format)
                let limitText = formatNumber(limit, format: format)
                let display: String
                switch format {
                case .percent:
                    display = "\(label): \(usedText)"
                default:
                    display = "\(label): \(usedText)/\(limitText)"
                }
                return SidecarMetricLineDTO(kind: "progress", label: label, display: display)
            case .values(let label, let values, _, _, _, _):
                let parts = values.map { MetricFormatter.string(for: $0, style: .row) }
                return SidecarMetricLineDTO(kind: "values", label: label, display: "\(label): \(parts.joined(separator: ", "))")
            case .chart(let label, let points, _):
                return SidecarMetricLineDTO(kind: "chart", label: label, display: "\(label): \(points.count) days")
            }
        }
    }

    private static func formatNumber(_ value: Double, format: ProgressFormat) -> String {
        switch format {
        case .percent:
            return MetricFormatter.number(value, kind: .percent, style: .row)
        case .dollars:
            return MetricFormatter.number(value, kind: .dollars, style: .row)
        case .count(let suffix):
            let core = MetricFormatter.number(value, kind: .count, style: .row)
            return suffix.isEmpty ? core : "\(core) \(suffix)"
        }
    }
}
