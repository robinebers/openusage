import Foundation

/// Stable, machine-facing metadata for one resource exported by `/v1/limits`.
///
/// Providers still produce `MetricLine` once. This metadata only names the subset that is useful to
/// programs and says how to select a scalar from an already-normalized line; presentation-only rows
/// simply have no descriptor and therefore cannot leak into the limits contract.
struct LimitResourceDescriptor: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, Encodable {
        case consumption
        case balance
    }

    enum Source: Hashable, Sendable {
        case progress
        case value(kind: MetricKind, label: String? = nil)
        /// A provider may report the same consumption as bounded progress or as an uncapped scalar.
        case progressOrValue(kind: MetricKind, label: String? = nil)
    }

    let key: String
    let kind: Kind
    let unit: String
    let source: Source
    var estimated = false
}

extension WidgetDescriptor {
    /// Adds one scalar to the public limits contract without changing the widget or provider mapper.
    func exportingLimit(
        _ key: String,
        kind: LimitResourceDescriptor.Kind = .consumption,
        unit: String,
        source: LimitResourceDescriptor.Source = .progress,
        estimated: Bool = false
    ) -> WidgetDescriptor {
        var copy = self
        copy.limitResources.append(LimitResourceDescriptor(
            key: key,
            kind: kind,
            unit: unit,
            source: source,
            estimated: estimated
        ))
        return copy
    }
}
