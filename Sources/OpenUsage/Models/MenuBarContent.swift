import Foundation

struct MenuBarGaugeItem: Equatable, Identifiable, Sendable {
    let id: String
    let provider: Provider
    let topFraction: Double
    let topPaceMark: Double?
    let topSeverity: WidgetData.MeterSeverity
    let bottomFraction: Double
    let bottomPaceMark: Double?
    let bottomSeverity: WidgetData.MeterSeverity
    let hasData: Bool

    init(
        id: String,
        provider: Provider,
        topFraction: Double = 0,
        topPaceMark: Double? = nil,
        topSeverity: WidgetData.MeterSeverity = .normal,
        bottomFraction: Double = 0,
        bottomPaceMark: Double? = nil,
        bottomSeverity: WidgetData.MeterSeverity = .normal,
        hasData: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.topFraction = topFraction
        self.topPaceMark = topPaceMark
        self.topSeverity = topSeverity
        self.bottomFraction = bottomFraction
        self.bottomPaceMark = bottomPaceMark
        self.bottomSeverity = bottomSeverity
        self.hasData = hasData
    }
}

struct MenuBarContent: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let provider: Provider
        let label: String
        let shortLabel: String
        let value: String
    }

    var style: MenuBarStyle = .text
    var items: [Item] = []
    var bars: [Double] = []
    var gauges: [MenuBarGaugeItem] = []
    var overflow = 0
    var updateAvailable = false

    init(
        style: MenuBarStyle = .text,
        items: [Item] = [],
        bars: [Double] = [],
        gauges: [MenuBarGaugeItem] = [],
        overflow: Int = 0,
        updateAvailable: Bool = false
    ) {
        self.style = style
        self.items = items
        self.bars = bars
        self.gauges = gauges
        self.overflow = overflow
        self.updateAvailable = updateAvailable
    }

    /// Convenience initializer preserving legacy signature for text items.
    init(items: [Item], overflow: Int = 0, updateAvailable: Bool = false) {
        self.style = .text
        self.items = items
        self.bars = []
        self.gauges = []
        self.overflow = overflow
        self.updateAvailable = updateAvailable
    }

    var isEmpty: Bool {
        switch style {
        case .text: return items.isEmpty
        case .bars: return bars.isEmpty
        case .gauge, .colorGauge: return gauges.isEmpty
        }
    }

    var accessibilityText: String {
        let shown: [String]
        switch style {
        case .text:
            shown = items.map { "\($0.provider.fullName) \($0.label) \($0.value)" }
        case .bars:
            shown = bars.map { "\(Int(($0 * 100).rounded()))%" }
        case .gauge, .colorGauge:
            shown = gauges.map { gauge in
                let top = Int((gauge.topFraction * 100).rounded())
                let bottom = Int((gauge.bottomFraction * 100).rounded())
                return "\(gauge.provider.fullName) 5h \(top)%, 7d \(bottom)%"
            }
        }
        let more = overflow > 0 ? ["\(overflow) more"] : []
        let update = updateAvailable ? ["Update available"] : []
        return (shown + more + update).joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    private static let genericWords: Set<String> = ["models", "bot", "usage"]

    static func build(
        board: PriorityBoard,
        accounts: [DashboardAccount] = [],
        limit: MenuBarLimit,
        style: MenuBarStyle = .text,
        now: Date = Date()
    ) -> MenuBarContent {
        guard limit != .iconOnly else { return MenuBarContent(style: style) }

        switch style {
        case .text:
            let shown = board.attention.prefix(limit.count).map { item in
                let label = item.data.title
                return MenuBarContent.Item(
                    id: item.id,
                    provider: item.provider,
                    label: label,
                    shortLabel: shortLabel(label),
                    value: item.data.menuBarValue
                )
            }
            return MenuBarContent(style: .text, items: Array(shown), overflow: board.attention.count - shown.count)

        case .bars:
            var boundedFractions: [Double] = []
            for account in accounts {
                for line in account.lines where line.isVisible && line.data.isBounded {
                    boundedFractions.append(line.data.fraction)
                }
            }
            if boundedFractions.isEmpty {
                boundedFractions = board.attention.compactMap { $0.data.isBounded ? $0.data.fraction : nil }
            }
            let shownBars = Array(boundedFractions.prefix(4))
            return MenuBarContent(style: .bars, bars: shownBars, overflow: max(0, boundedFractions.count - shownBars.count))

        case .gauge, .colorGauge:
            // Order accounts prioritizing those with items needing attention on the board
            let attentionProviderIDs = Set(board.attention.map(\.provider.id))
            let sortedAccounts = accounts.sorted { a, b in
                let aAttn = attentionProviderIDs.contains(a.provider.id)
                let bAttn = attentionProviderIDs.contains(b.provider.id)
                if aAttn != bAttn { return aAttn }
                return false
            }

            var gaugeItems: [MenuBarGaugeItem] = []
            for account in sortedAccounts {
                let boundedLines = account.lines.filter { $0.isVisible && $0.data.isBounded }
                guard !boundedLines.isEmpty else { continue }

                var top5hLine: DashboardLine?
                var bottom7dLine: DashboardLine?

                for line in boundedLines {
                    let key = line.descriptor.key.lowercased()
                    let title = line.data.title.lowercased()
                    let label = line.descriptor.metricLabel.lowercased()

                    let durationMs = line.data.periodDurationMs
                    let isShortDuration = durationMs.map { $0 <= 24 * 3600 * 1000 } ?? false
                    let isLongDuration = durationMs.map { $0 > 24 * 3600 * 1000 && $0 <= 14 * 24 * 3600 * 1000 } ?? false

                    let is5h = key.contains("session") || title.contains("session") || title.contains("5h") || label.contains("session") || isShortDuration
                    let is7d = key.contains("weekly") || title.contains("weekly") || title.contains("7d") || label.contains("weekly") || isLongDuration

                    if is5h && top5hLine == nil {
                        top5hLine = line
                    } else if is7d && bottom7dLine == nil {
                        bottom7dLine = line
                    }
                }

                // If not explicitly identified as 5h/7d, fallback to sorting by duration or line order
                if top5hLine == nil && bottom7dLine == nil {
                    if boundedLines.count >= 2 {
                        let sortedByDuration = boundedLines.sorted { a, b in
                            (a.data.periodDurationMs ?? Int.max) < (b.data.periodDurationMs ?? Int.max)
                        }
                        top5hLine = sortedByDuration[0]
                        bottom7dLine = sortedByDuration[1]
                    } else {
                        bottom7dLine = boundedLines[0]
                    }
                } else if top5hLine == nil, let b = bottom7dLine {
                    top5hLine = boundedLines.first { $0.id != b.id }
                } else if bottom7dLine == nil, let t = top5hLine {
                    bottom7dLine = boundedLines.first { $0.id != t.id }
                }

                func evaluateSeverity(_ line: DashboardLine?) -> WidgetData.MeterSeverity {
                    guard let line else { return .normal }
                    if line.data.fraction >= 1.0 { return .critical }
                    switch line.data.meterState(now: now) {
                    case .runningOut: return .critical
                    case .closeToLimit: return .warning
                    case .healthy: return .normal
                    case .spent: return .critical
                    case .unpaced, .noData: return line.data.severity
                    }
                }

                let item = MenuBarGaugeItem(
                    id: account.id,
                    provider: account.provider,
                    topFraction: top5hLine?.data.fraction ?? 0,
                    topPaceMark: top5hLine?.data.paceMark(now: now),
                    topSeverity: evaluateSeverity(top5hLine),
                    bottomFraction: bottom7dLine?.data.fraction ?? 0,
                    bottomPaceMark: bottom7dLine?.data.paceMark(now: now),
                    bottomSeverity: evaluateSeverity(bottom7dLine),
                    hasData: top5hLine != nil || bottom7dLine != nil
                )
                gaugeItems.append(item)
            }

            // Fallback for previews or empty accounts where board has attention items
            if gaugeItems.isEmpty && !board.attention.isEmpty {
                for item in board.attention {
                    let isBurning: Bool
                    if case .burningFast = item.reason {
                        isBurning = true
                    } else {
                        isBurning = false
                    }
                    let gaugeItem = MenuBarGaugeItem(
                        id: item.id,
                        provider: item.provider,
                        topFraction: item.data.fraction,
                        topPaceMark: item.data.paceMark(now: now),
                        topSeverity: isBurning ? .critical : item.data.severity,
                        bottomFraction: item.data.fraction,
                        bottomPaceMark: item.data.paceMark(now: now),
                        bottomSeverity: item.data.severity,
                        hasData: true
                    )
                    gaugeItems.append(gaugeItem)
                }
            }

            let shownGauges = Array(gaugeItems.prefix(limit.count))
            return MenuBarContent(
                style: style,
                gauges: shownGauges,
                overflow: max(0, gaugeItems.count - shownGauges.count)
            )
        }
    }

    static func shortLabel(_ label: String) -> String {
        var words = label.split(separator: " ")
        guard words.count > 1, let last = words.last, genericWords.contains(last.lowercased()) else { return label }
        words.removeLast()
        return words.joined(separator: " ")
    }
}
