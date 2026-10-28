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
