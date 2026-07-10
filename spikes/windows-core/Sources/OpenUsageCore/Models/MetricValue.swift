import Foundation

/// One measured number on a metric row, carried raw so that formatting happens only at the display
/// edge (see `MetricFormatter`) instead of being baked into a string the way `.text` rows used to.
///
/// A single row can hold several values — a daily-spend row carries dollars *and* tokens, a Codex
/// credits row carries dollars *and* a credit count — and each widget chooses which to render via
/// `ValueSelection`. That's what lets one row back a cost-only tile, a tokens-only tile, and a
/// combined tile without the mapper emitting the data three times.
struct MetricValue: Hashable, Sendable, Codable {
    /// The raw magnitude: USD for `.dollars`, 0...100 for `.percent`, an absolute count otherwise.
    var number: Double
    /// How this number prints ($ / % / plain count). Distinct per value within a row, which is what
    /// lets a widget pick "the dollars one" or "the count one" by kind.
    var kind: MetricKind
    /// Unit noun shown after the number ("tokens", "credits", "available"). `nil` renders the number
    /// bare — a dollar amount takes its trailing word from the widget (`unboundedValueWord`) instead.
    var label: String?
    /// True when the number is imputed locally rather than measured or billed — it drives the ⓘ note.
    /// Per value because a spend row's dollars are an estimate while its token count is real.
    var estimated: Bool

    init(number: Double, kind: MetricKind, label: String? = nil, estimated: Bool = false) {
        self.number = number
        self.kind = kind
        self.label = label
        self.estimated = estimated
    }
}

/// Which of a row's values a widget renders — the seam that lets one `.values` row back several tiles
/// (cost-only, tokens-only, both) while the data is produced exactly once.
enum ValueSelection: Hashable, Sendable {
    /// Every value, in order — the combined reading, e.g. "$4.08 · 1.2M tokens".
    case all
    /// Only the values of one kind: `.dollars` for a cost-only tile, `.count` for a tokens-only tile.
    case kind(MetricKind)

    func apply(to values: [MetricValue]) -> [MetricValue] {
        switch self {
        case .all:
            return values
        case .kind(let kind):
            return values.filter { $0.kind == kind }
        }
    }
}
