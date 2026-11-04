import Foundation

/// The % left at or under which a limit turns Warning (orange) and Critical (red). Critical always sits
/// under Warning: moving one onto or past the other pushes the other one step along.
struct PriorityLimits: Hashable, Sendable {
    static let step = 5
    static let warningRange = 20...70
    static let criticalRange = 5...25
    static let standard = PriorityLimits(warning: 30, critical: 10)

    static let warningOptions = Array(stride(from: warningRange.upperBound, through: warningRange.lowerBound, by: -step))
    static let criticalOptions = Array(stride(from: criticalRange.upperBound, through: criticalRange.lowerBound, by: -step))

    var warning: Int {
        didSet { if critical >= warning { critical = warning - Self.step } }
    }

    var critical: Int {
        didSet { if warning <= critical { warning = critical + Self.step } }
    }

    init(warning: Int, critical: Int) {
        self.warning = Self.snapped(warning, to: Self.warningRange)
        self.critical = min(Self.snapped(critical, to: Self.criticalRange), self.warning - Self.step)
    }

    private static func snapped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        let stepped = Int((Double(value) / Double(step)).rounded()) * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}
