import Foundation

struct LimitResourceDescriptor: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, Encodable {
        case consumption
        case balance
    }

    enum Source: Hashable, Sendable {
        case progress
        case value(kind: MetricKind, label: String? = nil)
        case progressOrValue(kind: MetricKind, label: String? = nil)
    }

    let key: String
    let kind: Kind
    let unit: String
    let source: Source

    /// The figure of a values line this resource reads.
    func value(in values: [MetricValue]) -> MetricValue? {
        switch source {
        case .progress:
            nil
        case .value(let kind, let label), .progressOrValue(let kind, let label):
            values.first { $0.kind == kind && (label == nil || $0.label == label) }
        }
    }
}

extension WidgetDescriptor {
    func exportingLimit(
        _ key: String,
        kind: LimitResourceDescriptor.Kind = .consumption,
        unit: String,
        source: LimitResourceDescriptor.Source = .progress
    ) -> WidgetDescriptor {
        var copy = self
        copy.limitResources.append(LimitResourceDescriptor(key: key, kind: kind, unit: unit, source: source))
        return copy
    }
}
