import Observation
import SwiftUI

/// The live data projected into the side-notch strip. It deliberately follows the menu bar's starred
/// metrics, so changing surfaces never introduces a second customization model.
struct SideNotchContent: Equatable {
    struct Metric: Equatable, Identifiable {
        let id: String
        let label: String
        let value: String
        let usedHeadline: String
        let fraction: Double
        let isBounded: Bool
        let resetText: String?
        let severity: WidgetData.MeterSeverity?
    }

    struct AvailableReset: Equatable {
        let count: Int
        let expiresAt: Date
        let severity: WidgetData.MeterSeverity?
    }

    struct Group: Equatable, Identifiable {
        let id: String
        let displayName: String
        let icon: IconSource
        let metrics: [Metric]
        let availableReset: AvailableReset?

        var primaryMetric: Metric { metrics[0] }
    }

    let groups: [Group]
}

@MainActor
enum SideNotchContentBuilder {
    static func build(
        groups: [ProviderMetrics],
        supportedMetrics: (Provider) -> [WidgetDescriptor] = { _ in [] },
        data: (WidgetDescriptor) -> WidgetData,
        title: (Provider) -> String = { $0.displayName },
        now: Date = Date()
    ) -> SideNotchContent {
        let resolved = groups.compactMap { group -> SideNotchContent.Group? in
            let supported = supportedMetrics(group.provider)
            let candidates = supported.isEmpty ? group.metrics : supported
            let recap = recapMetrics(from: candidates, pinned: group.metrics, data: data)
            let availableReset = availableReset(from: candidates, data: data, now: now)
            let metrics = recap.map { descriptor, source -> SideNotchContent.Metric in
                // The Side Notch is deliberately usage-first, independent of the dashboard/menu-bar
                // Used/Left preference. This matches the physical direction of the fill and keeps the
                // compact reading unambiguous.
                var widget = source
                widget.displayMode = .used
                return SideNotchContent.Metric(
                    id: descriptor.id,
                    label: recapLabel(for: descriptor, data: widget),
                    value: widget.menuBarValue,
                    usedHeadline: "\(widget.menuBarValue) Used",
                    fraction: widget.fraction,
                    isBounded: widget.isBounded,
                    resetText: widget.resetsAt == nil ? nil : widget.boundedTrailingText(now: now),
                    severity: SideNotchMeter.severity(for: widget, now: now)
                )
            }
            guard !metrics.isEmpty else { return nil }
            return SideNotchContent.Group(
                id: group.provider.id,
                displayName: title(group.provider),
                icon: group.provider.icon,
                metrics: metrics,
                availableReset: availableReset
            )
        }
        return SideNotchContent(groups: resolved)
    }

    /// A provider recap is not a second user-configured metric list. Stars decide which provider cards
    /// appear; once present, the recap puts the shortest window first: session, then weekly or monthly.
    /// The first row also drives the compact ring. Providers without these shapes fall back to their
    /// starred metrics so every existing integration remains useful.
    private static func recapMetrics(
        from descriptors: [WidgetDescriptor],
        pinned: [WidgetDescriptor],
        data: (WidgetDescriptor) -> WidgetData
    ) -> [(WidgetDescriptor, WidgetData)] {
        let resolved = descriptors.map { ($0, data($0)) }.filter { $0.1.hasData && $0.1.isBounded }
        let monthly = resolved.first { isMonthly($0.0, data: $0.1) }
        let weekly = resolved.first { isWeekly($0.0, data: $0.1) }
        let session = resolved.first { isSession($0.0, data: $0.1) }

        var recap: [(WidgetDescriptor, WidgetData)] = []
        if let session { recap.append(session) }
        if let subscription = weekly ?? monthly,
           !recap.contains(where: { $0.0.id == subscription.0.id }) {
            recap.append(subscription)
        }
        if !recap.isEmpty { return recap }

        return pinned.compactMap { descriptor in
            let widget = data(descriptor)
            return widget.hasData ? (descriptor, widget) : nil
        }
    }

    /// Reset credits are provider-level account data rather than a usage window. Keep them outside the
    /// ring-driving recap metrics and show them only when both an available credit and its real expiry
    /// are known. The soonest expiry is the actionable one when an account has several credits.
    private static func availableReset(
        from descriptors: [WidgetDescriptor],
        data: (WidgetDescriptor) -> WidgetData,
        now: Date
    ) -> SideNotchContent.AvailableReset? {
        for descriptor in descriptors {
            let widget = data(descriptor)
            guard widget.hasData,
                  widget.showsResetExpiries,
                  widget.resetCreditCount > 0,
                  let expiresAt = widget.expiriesAt.min()
            else { continue }
            return SideNotchContent.AvailableReset(
                count: widget.resetCreditCount,
                expiresAt: expiresAt,
                severity: widget.expirySeverity(now: now)
            )
        }
        return nil
    }

    private static func recapLabel(for descriptor: WidgetDescriptor, data: WidgetData) -> String {
        if isMonthly(descriptor, data: data) { return "Monthly Limit" }
        if isWeekly(descriptor, data: data) { return "Weekly Limit" }
        if isSession(descriptor, data: data) { return "Session Limit" }
        return descriptor.metricLabel
    }

    private static func isSession(_ descriptor: WidgetDescriptor, data: WidgetData) -> Bool {
        data.isSessionWindow || searchText(descriptor, data: data).contains("session")
    }

    private static func isMonthly(_ descriptor: WidgetDescriptor, data: WidgetData) -> Bool {
        let text = searchText(descriptor, data: data)
        if text.contains("monthly") || text.contains("month") { return true }
        guard let period = data.periodDurationMs else { return false }
        return period >= 28 * 24 * 60 * 60 * 1000
    }

    private static func isWeekly(_ descriptor: WidgetDescriptor, data: WidgetData) -> Bool {
        let text = searchText(descriptor, data: data)
        if text.contains("weekly") || text.contains("week") { return true }
        guard let period = data.periodDurationMs else { return false }
        return period >= 6 * 24 * 60 * 60 * 1000 && period < 28 * 24 * 60 * 60 * 1000
    }

    private static func searchText(_ descriptor: WidgetDescriptor, data: WidgetData) -> String {
        "\(descriptor.id) \(descriptor.metricLabel) \(data.title)".lowercased()
    }
}

/// Side-notch traffic lights intentionally differ from the dashboard's pacing palette: a projection
/// that crosses the limit is advance warning (yellow), while red is reserved for an account that has
/// already consumed at least 90% of its allowance. Normal usage is green, matching Codenotch's rings.
enum SideNotchMeter {
    static func severity(for data: WidgetData, now: Date = Date()) -> WidgetData.MeterSeverity? {
        guard data.hasData, let limit = data.limit, limit > 0 else { return nil }
        if data.used / limit >= 0.9 { return .critical }
        switch data.meterState(now: now) {
        case .runningOut, .closeToLimit: return .warning
        default: return .normal
        }
    }
}

/// Shared rail measurements. The transparent panel stays fixed, while the visible notch grows by one
/// provider row until it reaches the panel's safe maximum and becomes scrollable.
enum SideNotchLayout {
    static let scale: CGFloat = 0.8
    static let collapsedWidth: CGFloat = 10 * scale
    static let collapsedHeight: CGFloat = 76 * scale
    static let stripWidth: CGFloat = 76 * scale
    static let detailGap: CGFloat = 11 * scale
    static let detailCardWidth: CGFloat = 270 * scale
    static let detailPointerWidth: CGFloat = 28 * scale
    static let detailWidth: CGFloat = stripWidth + detailGap + detailCardWidth + detailPointerWidth
    static let maximumHeight: CGFloat = 720 * scale
    static let verticalOffset: CGFloat = -7 * scale
    static let contentVerticalPadding: CGFloat = 60 * scale

    static let rowSpacing: CGFloat = 30 * scale
    private static let rowHeight: CGFloat = 73 * scale

    static func stripHeight(subscriptionCount: Int) -> CGFloat {
        let count = max(subscriptionCount, 1)
        let rows = CGFloat(count) * rowHeight
        let spacing = CGFloat(count - 1) * rowSpacing
        return min(maximumHeight, contentVerticalPadding * 2 + rows + spacing)
    }
}

/// Shared state between the SwiftUI notch surface and its AppKit window owner. AppKit owns window
/// geometry; SwiftUI owns only the interaction state that determines which geometry is needed.
@MainActor
@Observable
final class SideNotchViewModel {
    var isExpanded = false
    var hoveredProviderID: String?
    var activatedProviderID: String?
    var expandedStripHeight = SideNotchLayout.stripHeight(subscriptionCount: 2)
    /// Provider-button frames in the root view's top-left coordinate space. AppKit's always-active
    /// tracking area uses these to bridge reliable hover into a non-activating borderless panel.
    @ObservationIgnored var providerFrames: [String: CGRect] = [:]

    func collapse() {
        activatedProviderID = nil
        hoveredProviderID = nil
        isExpanded = false
    }

    func provider(atVerticalOffset offset: CGFloat) -> String? {
        providerFrames.first(where: { $0.value.minY ... $0.value.maxY ~= offset })?.key
    }
}

/// The screen-edge surface inspired by Codenotch: a quiet handle when closed, a vertical run of
/// provider rings when opened, and a provider detail card that grows leftward on hover.
struct SideNotchView: View {
    let container: AppContainer
    @Bindable var model: SideNotchViewModel
    let openDashboard: () -> Void
    let openSettings: () -> Void

    private let stripWidth = SideNotchLayout.stripWidth
    private let ringSize: CGFloat = 46 * SideNotchLayout.scale
    private let surfaceHeight = SideNotchLayout.maximumHeight
    private var content: SideNotchContent {
        SideNotchContentBuilder.build(
            groups: container.layout.pinnedGroups,
            supportedMetrics: { container.layout.orderedSupportedMetrics(for: $0.id) },
            data: { container.dataStore.data(for: $0) },
            title: { container.displayName(for: $0) }
        )
    }
    private var expandedStripHeight: CGFloat {
        let count = container.privacy.concealUsage ? 1 : max(content.groups.count, 1)
        return SideNotchLayout.stripHeight(subscriptionCount: count)
    }
    var body: some View {
        ZStack(alignment: .trailing) {
            if model.isExpanded,
               !container.privacy.concealUsage,
               let hovered = content.groups.first(where: { $0.id == model.hoveredProviderID }) {
                SideNotchDetailSurface(
                    group: hovered,
                    groups: content.groups,
                    centerOffset: detailOffset(for: hovered),
                    trailingInset: stripWidth + SideNotchLayout.detailGap,
                    fill: sideNotchFill,
                    reduceMotion: ReduceAnimationsSetting.isEnabled
                )
                    .transition(
                        .opacity.animation(.easeOut(duration: 0.18))
                    )
            }

            // Keep the expanded rail at its final layout and spring its rendered surface out from the
            // compact handle. Scaling the whole surface makes provider rows fan out from the center,
            // matching Codenotch; animating only the frame made the ScrollView relayout from its top.
            SideNotchEdgeShape()
                .fill(.black)
                .frame(width: stripWidth, height: expandedStripHeight)
                .overlay {
                    stripContent
                        .frame(width: stripWidth)
                }
                .offset(y: model.isExpanded ? SideNotchLayout.verticalOffset : 0)
                .scaleEffect(
                    x: model.isExpanded ? 1 : SideNotchLayout.collapsedWidth / stripWidth,
                    y: model.isExpanded ? 1 : SideNotchLayout.collapsedHeight / expandedStripHeight,
                    anchor: .trailing
                )
                .opacity(model.isExpanded ? 1 : 0)
                .contentShape(Rectangle())
                .allowsHitTesting(model.isExpanded)
                .onTapGesture {
                    // Empty space closes the surface; provider buttons consume their own clicks.
                    model.collapse()
                }
                .animation(
                    ReduceAnimationsSetting.isEnabled
                        ? nil
                        : .spring(response: 0.32, dampingFraction: 0.72),
                    value: model.isExpanded
                )
                .animation(
                    ReduceAnimationsSetting.isEnabled
                        ? nil
                        : .spring(response: 0.3, dampingFraction: 0.86),
                    value: expandedStripHeight
                )

            // Preserve the exact compact silhouette at rest, then hand it off immediately to the
            // scaled rail as the spring begins.
            SideNotchEdgeShape()
                .fill(.black)
                .frame(
                    width: SideNotchLayout.collapsedWidth,
                    height: SideNotchLayout.collapsedHeight
                )
                .opacity(model.isExpanded ? 0 : 1)
                .allowsHitTesting(false)
                .animation(
                    ReduceAnimationsSetting.isEnabled ? nil : .easeOut(duration: 0.08),
                    value: model.isExpanded
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .environment(\.colorScheme, .dark)
        .coordinateSpace(name: "openusage.sideNotch")
        .onChange(of: expandedStripHeight, initial: true) { _, height in
            model.expandedStripHeight = height
        }
        .contextMenu {
            Button("Settings", systemImage: "gearshape", action: openSettings)
            Divider()
            Button("Quit OpenUsage", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var stripContent: some View {
        if container.privacy.concealUsage {
            Button(action: openDashboard) {
                VStack(spacing: 8 * SideNotchLayout.scale) {
                    ProviderIcon(source: .providerMark("openusage"), inset: 0.08)
                        .frame(width: 30 * SideNotchLayout.scale, height: 30 * SideNotchLayout.scale)
                    Text("Open")
                        .font(.system(size: 13 * SideNotchLayout.scale, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("OpenUsage, usage hidden while the screen is shared")
        } else if content.groups.isEmpty {
            Button(action: openDashboard) {
                VStack(spacing: 8 * SideNotchLayout.scale) {
                    ProviderIcon(source: .providerMark("openusage"), inset: 0.08)
                        .frame(width: 30 * SideNotchLayout.scale, height: 30 * SideNotchLayout.scale)
                    Text("Open")
                        .font(.system(size: 13 * SideNotchLayout.scale, weight: .semibold))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open OpenUsage Dashboard")
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: SideNotchLayout.rowSpacing) {
                    ForEach(content.groups) { group in
                        providerButton(group)
                    }
                }
                .padding(.vertical, SideNotchLayout.contentVerticalPadding)
            }
            .scrollIndicators(.never)
        }
    }

    private func providerButton(_ group: SideNotchContent.Group) -> some View {
        let metric = group.primaryMetric
        return Button {
            activate(group)
        } label: {
            VStack(spacing: 7 * SideNotchLayout.scale) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.17), lineWidth: 6 * SideNotchLayout.scale)
                    if metric.isBounded {
                        Circle()
                            .trim(from: 0, to: min(max(metric.fraction, 0), 1))
                            .stroke(
                                sideNotchFill(metric.severity),
                                style: StrokeStyle(lineWidth: 4 * SideNotchLayout.scale, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .padding(1 * SideNotchLayout.scale)
                    }
                    ProviderIcon(source: group.icon, inset: 0.12)
                        .frame(width: 25 * SideNotchLayout.scale, height: 25 * SideNotchLayout.scale)
                        .foregroundStyle(.white)
                }
                .frame(width: ringSize, height: ringSize)
                .scaleEffect(model.activatedProviderID == group.id ? 0.84 : 1)
                .rotationEffect(.degrees(model.activatedProviderID == group.id ? 8 : 0))

                Text(metric.value)
                    .font(.system(size: 17 * SideNotchLayout.scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: stripWidth)
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(
            ReduceAnimationsSetting.isEnabled
                ? nil
                : .spring(response: 0.2, dampingFraction: 0.52),
            value: model.activatedProviderID
        )
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("openusage.sideNotch"))
        } action: { frame in
            model.providerFrames[group.id] = frame
        }
        .accessibilityLabel("\(group.displayName), \(metric.label) \(metric.value)")
    }

    private func detailOffset(for group: SideNotchContent.Group) -> CGFloat {
        guard let frame = model.providerFrames[group.id] else { return 0 }
        return frame.midY - surfaceHeight / 2
    }

    private func activate(_ group: SideNotchContent.Group) {
        guard model.activatedProviderID == nil else { return }
        if ReduceAnimationsSetting.isEnabled {
            model.collapse()
            openDashboard()
            return
        }

        model.activatedProviderID = group.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            guard model.activatedProviderID == group.id else { return }
            model.activatedProviderID = nil
            try? await Task.sleep(for: .milliseconds(130))
            guard model.isExpanded else { return }
            model.collapse()
            openDashboard()
        }
    }

    private func sideNotchFill(_ severity: WidgetData.MeterSeverity?) -> AnyShapeStyle {
        switch severity {
        case .normal: AnyShapeStyle(Color(nsColor: .systemGreen))
        case .warning: AnyShapeStyle(Color(nsColor: .systemYellow))
        case .critical: AnyShapeStyle(Color(nsColor: .systemRed))
        case nil: AnyShapeStyle(.secondary)
        }
    }
}

/// Codenotch-style edge rail: the screen-side edge stays flush while a concave curl flows into an
/// equal convex corner. Two quarter-circle curves reproduce Codenotch's horizontal midpoint tangent
/// instead of approximating the shoulder with one generic S-curve.
private struct SideNotchEdgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2, rect.height / 4)
        let curve = radius * 0.552_284_749_8
        let midX = rect.maxX - radius
        let outerX = rect.maxX - radius * 2
        let upperJoinY = rect.minY + radius
        let upperEdgeY = rect.minY + radius * 2
        let lowerEdgeY = rect.maxY - radius * 2
        let lowerJoinY = rect.maxY - radius

        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: midX, y: upperJoinY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + curve),
            control2: CGPoint(x: midX + curve, y: upperJoinY)
        )
        path.addCurve(
            to: CGPoint(x: outerX, y: upperEdgeY),
            control1: CGPoint(x: midX - curve, y: upperJoinY),
            control2: CGPoint(x: outerX, y: upperEdgeY - curve)
        )
        path.addLine(to: CGPoint(x: outerX, y: lowerEdgeY))
        path.addCurve(
            to: CGPoint(x: midX, y: lowerJoinY),
            control1: CGPoint(x: outerX, y: lowerEdgeY + curve),
            control2: CGPoint(x: midX - curve, y: lowerJoinY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control1: CGPoint(x: midX + curve, y: lowerJoinY),
            control2: CGPoint(x: rect.maxX, y: rect.maxY - curve)
        )
        path.closeSubpath()
        return path
    }
}
