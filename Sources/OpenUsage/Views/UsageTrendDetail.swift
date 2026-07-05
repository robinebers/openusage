import SwiftUI

/// The detail-on-demand popover for a Usage Trend row: a larger, readable bar chart with the peak (or
/// the hovered day) called out, the window's date range, and the source note. Hovering a bar highlights
/// it and swaps the readout to that exact day — the same detail-on-demand the original app shows.
struct UsageTrendDetail: View {
    let title: String
    let points: [MetricChartPoint]
    let note: String?
    /// Reports whether the cursor is inside the popover, so the trigger can keep it open while the user
    /// moves from the inline row into the chart, and close it once they leave both.
    var onHoverChange: (Bool) -> Void

    @State private var activeIndex: Int?

    private static let chartHeight: CGFloat = 76
    private static let width: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chart
            axis
            if let note, !note.isEmpty {
                PopoverSourceNote(text: note)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        // A refresh can replace `points` while the popover is open; drop the selection so the highlight
        // and readout never point at a day that shifted out from under the cursor.
        .onChange(of: points) { activeIndex = nil }
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false); activeIndex = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(readout)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        let maxValue = max(1, points.map(\.value).max() ?? 1)
        // Same blue as a healthy meter; the hovered bar stays full-strength while the rest dim, so the
        // selection reads without a second color.
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(points.indices, id: \.self) { index in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.chartHeight)
                    // The full column is the hover target so even short bars are easy to hit.
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Theme.meterFill(.normal))
                            .frame(height: barHeight(points[index].value, max: maxValue))
                            .opacity(activeIndex == nil || activeIndex == index ? 1 : 0.35)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { activeIndex = index }
                    }
            }
        }
        .frame(height: Self.chartHeight)
        // Clear the selection when the cursor leaves the bars for the header/axis/note (still inside the
        // popover), so the readout falls back to the peak instead of freezing on the last bar.
        .onContinuousHover { phase in if case .ended = phase { activeIndex = nil } }
        .animation(.easeOut(duration: 0.12), value: activeIndex)
    }

    private var axis: some View {
        HStack {
            Text(points.first?.label ?? "")
            Spacer()
            Text(points.last?.label ?? "")
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var peakIndex: Int? { points.indices.max { points[$0].value < points[$1].value } }

    /// The hovered day, or the peak when nothing is hovered — the one figure the bars can't label.
    private var readout: String {
        if let activeIndex, points.indices.contains(activeIndex) {
            return "\(points[activeIndex].label) · \(points[activeIndex].readout)"
        }
        if let peakIndex { return "peak \(points[peakIndex].readout)" }
        return ""
    }

    private func barHeight(_ value: Double, max maxValue: Double) -> CGFloat {
        guard value > 0 else { return 2 }
        return max(Self.chartHeight * 0.06, Self.chartHeight * min(1, value / maxValue))
    }
}

/// Drives the hover-revealed trend popover: opens after a short dwell while the inline row is hovered,
/// and closes once the cursor has left BOTH the row and the popover (a brief grace lets the cursor
/// travel between them). An `@Observable` reference type so a SwiftUI `View` can hold it in `@State`
/// and bind `isPresented` to the popover — value-type closure capture can't track this state reliably.
@MainActor
@Observable
final class TrendHoverState {
    var isPresented = false

    /// Every live coordinator, so the menu-bar panel's close path can dismiss any open trend popover —
    /// the dashboard view tree (and this `@State`) survives the panel's `orderOut`, so `.onDisappear`
    /// alone wouldn't fire and the popover could orphan or re-show on the next open.
    @ObservationIgnored private static let live = NSHashTable<TrendHoverState>.weakObjects()

    static func dismissAll() {
        for state in live.allObjects { state.dismiss() }
    }

    @ObservationIgnored private var overInline = false
    @ObservationIgnored private var overDetail = false
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// 400ms reveal matches the app's hover-tooltip dwell (see `HoverTooltip`), so the trend popover
    /// opens on the same deliberate intent as every other hover affordance; 180ms grace lets the cursor
    /// cross from the row into the popover without it closing. Injectable so tests drive it without sleeps.
    private let revealDelay: Duration
    private let hideGrace: Duration

    init(revealDelay: Duration = .milliseconds(400), hideGrace: Duration = .milliseconds(180)) {
        self.revealDelay = revealDelay
        self.hideGrace = hideGrace
        Self.live.add(self)
    }

    func inlineHover(_ active: Bool) {
        overInline = active
        active ? scheduleShow() : scheduleHide()
    }

    func detailHover(_ inside: Bool) {
        overDetail = inside
        if inside { hideTask?.cancel(); hideTask = nil } else { scheduleHide() }
    }

    /// Force the popover shut (popover/dashboard teardown), so it can't orphan on screen.
    func dismiss() {
        showTask?.cancel(); showTask = nil
        hideTask?.cancel(); hideTask = nil
        overInline = false
        overDetail = false
        isPresented = false
    }

    private func scheduleShow() {
        hideTask?.cancel(); hideTask = nil
        guard !isPresented, showTask == nil else { return }
        let delay = revealDelay
        showTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if overInline { isPresented = true }
            showTask = nil
        }
    }

    private func scheduleHide() {
        showTask?.cancel(); showTask = nil
        hideTask?.cancel()
        let delay = hideGrace
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if !overInline, !overDetail { isPresented = false }
            hideTask = nil
        }
    }
}
