import Foundation

struct WidgetData: Hashable {
    static let noDataValue = "—"
    static let noDataDetail = "No data"

    let title: String
    let kind: MetricKind
    let used: Double
    var limit: Double?
    var displayMode: WidgetDisplayMode = .used
    var resetDisplayMode: ResetDisplayMode = .relative
    var resetsAt: Date?
    var expiriesAt: [Date] = []
    var showsResetExpiries: Bool = false
    var periodDurationMs: Int?
    var valueTextOverride: String?
    var unboundedValueWord: String?
    var hasData: Bool = true
    var values: [MetricValue] = []
    var traySuffix: String?
    var sessionStartSignal: SessionStartSignal?

    enum SessionStartSignal: Hashable {
        /// Zero usage is the fresh signal. Antigravity reports a reset instant even for an untouched
        /// window and its mapper rounds the fresh pool's fraction-derived percent to 0, so `used == 0`
        /// is what marks the window as fresh.
        case zeroUsage
        /// A missing reset date is the fresh signal: by the time a row carries one, a reset instant
        /// means the window started. Claude's five-hour block is created by the first message, so it
        /// simply reports no `resets_at` until then; OpenCode does report a placeholder for an untouched
        /// window, which `OpenCodeUsageMapper` drops at capture time. Zero usage is NOT trusted here:
        /// both APIs report utilization in whole percents, so an in-flight window under 1% also reads
        /// 0 — the reset date is what tells the two apart.
        case missingResetDate
    }
    var isBounded: Bool { limit != nil }

    var hasMeterStyleToggle: Bool {
        hasData && isBounded && valueTextOverride == nil
    }

    var displayedValue: Double {
        guard displayMode == .remaining, let limit else { return used }
        return max(0, limit - used)
    }

    var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max(roundedDisplayValue / limit, 0), 1)
    }

    var remainingFraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max((limit - used) / limit, 0), 1)
    }

    enum MeterSeverity: Hashable {
        case normal, warning, critical
    }

    enum MeterState: Hashable {
        case noData
        case spent
        case runningOut
        case closeToLimit
        case healthy
        case level(MeterSeverity)

        var severity: MeterSeverity? {
            switch self {
            case .noData: return nil
            case .spent, .runningOut: return .critical
            case .closeToLimit: return .warning
            case .healthy: return .normal
            case .level(let severity): return severity
            }
        }
    }

    private var roundedDisplayValue: Double {
        roundedAtDisplayPrecision(displayedValue)
    }

    private func roundedAtDisplayPrecision(_ value: Double) -> Double {
        switch kind {
        case .percent: return value.rounded()
        case .count: return (value * 10).rounded() / 10
        case .dollars: return (value * 100).rounded() / 100
        }
    }

    var valueText: String {
        guard hasData else { return Self.noDataValue }
        if let valueTextOverride { return valueTextOverride }
        if let first = values.first {
            return MetricFormatter.number(first.number, kind: first.kind, style: .row)
        }
        return format(displayedValue)
    }

    var menuBarValue: String {
        guard hasData else { return valueText }
        if let limit, limit > 0 {
            if kind == .percent {
                let percent = min(100, max(0, Int((displayedValue / limit * 100).rounded())))
                return "\(percent)%"
            }
            return MetricFormatter.number(displayedValue, kind: kind, style: .tray)
        }
        if let first = values.first {
            if let traySuffix, first.kind == .count {
                return "\(MetricFormatter.number(first.number, kind: .count, style: .tray)) \(traySuffix)"
            }
            return MetricFormatter.string(for: first, style: .tray)
        }
        if let valueTextOverride { return valueTextOverride }
        return MetricFormatter.number(displayedValue, kind: kind, style: .tray)
    }

    var unboundedDetail: String {
        guard hasData else { return Self.noDataDetail }
        if let valueTextOverride { return valueTextOverride }
        if !values.isEmpty {
            if values.count == 1 {
                let value = values[0]
                if value.kind == .dollars, let word = unboundedValueWord {
                    return "\(MetricFormatter.number(value.number, kind: .dollars, style: .row)) \(word)"
                }
                return MetricFormatter.string(for: value, style: .row)
            }
            return values.map { MetricFormatter.string(for: $0, style: .row) }.joined(separator: " · ")
        }
        return "\(valueText) \(unboundedValueWord ?? displayMode.label.lowercased())"
    }

    static let expiryWarningWindow: TimeInterval = 7 * 24 * 60 * 60
    static let expiryCriticalWindow: TimeInterval = 48 * 60 * 60

    static func expirySeverity(secondsRemaining: TimeInterval) -> MeterSeverity {
        if secondsRemaining <= expiryCriticalWindow { return .critical }
        if secondsRemaining <= expiryWarningWindow { return .warning }
        return .normal
    }

    /// The figure of a row carrying reset expiries takes the colour of the reset that expires next.
    func expirySeverity(now: Date = Date()) -> MeterSeverity? {
        guard hasData, let soonest = expiriesAt.min() else { return nil }
        return Self.expirySeverity(secondsRemaining: soonest.timeIntervalSince(now))
    }

    var resetCreditCount: Int {
        Int((values.first?.number ?? 0).rounded(.down))
    }

    private func format(_ value: Double) -> String {
        MetricFormatter.number(value, kind: kind, style: .row)
    }
}

extension WidgetData {
    private var paceContext: (limit: Double, resetsAt: Date, period: TimeInterval)? {
        guard hasData, let limit, limit > 0, let resetsAt,
              let periodDurationMs, periodDurationMs > 0 else { return nil }
        return (limit, resetsAt, TimeInterval(periodDurationMs) / 1000)
    }

    func meterState(now: Date = Date()) -> MeterState {
        guard hasData, let limit, limit > 0 else { return hasData ? .level(.normal) : .noData }
        if roundedAtDisplayPrecision(limit - used) <= 0 { return .spent }
        guard let pace = pace(now: now) else { return levelState(used: used, limit: limit) }
        switch pace.status {
        case .ahead:
            return .healthy
        case .onTrack:
            let spare = Int(((1 - pace.projectedFraction) * 100).rounded())
            return spare >= 1 ? .closeToLimit : .runningOut
        case .behind:
            return .runningOut
        }
    }

    func paceTooltip(now: Date = Date()) -> String? {
        if meterState(now: now) == .spent { return "Limit reached" }
        guard let pace = pace(now: now) else { return nil }
        let percent = { (share: Double) in Int((share * 100).rounded()) }
        switch pace.status {
        case .ahead: return "~\(percent(1 - pace.projectedFraction))% left at reset"
        case .onTrack: return "~\(percent(pace.projectedFraction))% used at reset"
        case .behind: return "~\(max(1, percent(pace.projectedFraction - 1)))% over limit at reset"
        }
    }

    private func pace(now: Date) -> (status: Pace.Status, projectedFraction: Double)? {
        guard !isFreshSessionWindow(now: now), let ctx = paceContext,
              let result = Pace.evaluate(used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                                         periodDuration: ctx.period, now: now)
        else { return nil }
        guard result.status == .ahead || used / ctx.limit >= 0.05 else { return nil }
        return (result.status, result.projectedUsage / ctx.limit)
    }

    private func levelState(used: Double, limit: Double) -> MeterState {
        let percentUsed = (min(max(used / limit, 0), 1) * 100).rounded()
        if percentUsed >= 90 { return .level(.critical) }
        if percentUsed >= 75 { return .level(.warning) }
        return .level(.normal)
    }

    func isFreshSessionWindow(now: Date = Date()) -> Bool {
        guard let signal = sessionStartSignal, hasData, limit != nil, used <= 0 else { return false }
        switch signal {
        case .zeroUsage:
            guard let resetsAt else { return false }
            return now < resetsAt
        case .missingResetDate:
            return resetsAt == nil
        }
    }
}
