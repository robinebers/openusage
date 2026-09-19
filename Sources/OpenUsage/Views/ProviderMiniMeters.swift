import SwiftUI

/// The two collapsed-header meter layouts a mini card can use (`MiniCardStyle`), plus the tiny bar
/// they share. Both draw `MiniMeter` values the provider card already computed, so a mini card is a
/// smaller rendering of the same numbers, never a second calculation.

/// The shared micro bar: the capsule meter from `WidgetRowView`, shrunk. Same semantic quaternary
/// track and same system severity fill, so it tracks light/dark and Increase Contrast with the
/// full-size bars.
struct MiniMeterBar: View {
    let severity: WidgetData.MeterSeverity?
    let fraction: Double
    var isOutdated: Bool = false

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(severity.map(Theme.meterFill) ?? AnyShapeStyle(Color.secondary))
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: density.miniMeterHeight)
        .opacity(isOutdated ? LastKnownMeterStore.outdatedOpacity : 1)
        .animation(Motion.spring, value: fraction)
    }
}

/// Single Row: the meters ride the header line as one segmented pill at the trailing edge, hairlines
/// between segments. Sized to hug its contents so the provider name keeps every point the pill
/// doesn't need.
struct MiniMeterPill: View {
    let meters: [MiniMeter]

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(meters.enumerated()), id: \.element.id) { index, meter in
                if index > 0 {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1, height: density.miniMeterPillHeight - 8)
                }
                HStack(spacing: 2) {
                    Text(meter.percentText)
                        .font(.system(size: density.miniMeterPointSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .opacity(meter.isOutdated ? LastKnownMeterStore.outdatedOpacity : 1)
                        .monospacedDigit()
                        // A truncated percentage is worse than no percentage: "31%" clipped to "3"
                        // reads as a real number. The pill keeps its width and the provider name
                        // gives way instead (see `fixedSize` below).
                        .fixedSize(horizontal: true, vertical: false)
                    MiniMeterBar(severity: meter.severity, fraction: meter.fraction,
                                 isOutdated: meter.isOutdated)
                        .frame(width: density.miniMeterBarWidth)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 3)
        .frame(height: density.miniMeterPillHeight)
        .background(Capsule().fill(.quaternary))
        // The pill is the payload of a collapsed header; under width pressure the provider name
        // truncates and the meters stay whole.
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MiniMeter.accessibilityLabel(meters))
    }
}

/// Detailed: the meters get their own line under the header, each under its metric name, aligned to
/// the start of the provider name so the second line reads as part of the header rather than a row.
struct MiniMeterLine: View {
    let meters: [MiniMeter]
    /// Distance from the header's leading edge to the provider name, so the columns line up under it.
    let leadingInset: CGFloat

    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(meters) { meter in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(meter.title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(meter.percentText)
                            .foregroundStyle(.primary)
                            .opacity(meter.isOutdated ? LastKnownMeterStore.outdatedOpacity : 1)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: density.miniMeterPointSize, weight: .semibold))
                    MiniMeterBar(severity: meter.severity, fraction: meter.fraction,
                                 isOutdated: meter.isOutdated)
                }
                // A cap, never a fixed width. `frame(width:)` here made three columns demand more
                // than the 320pt popover's content area allows, which pushed the whole dashboard
                // wider and squeezed out its side padding. Capped-and-flexible keeps columns aligned
                // across providers when there is room and lets them give way when there isn't.
                .frame(maxWidth: density.miniMeterColumnWidth)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MiniMeter.accessibilityLabel(meters))
    }
}

extension MiniMeter {
    /// One spoken summary for a whole mini card ("Session 8 percent, Weekly 30 percent"), so the bars
    /// read as a sentence instead of a run of loose numbers.
    static func accessibilityLabel(_ meters: [MiniMeter]) -> String {
        meters.map { meter in
            let reading = "\(meter.title) \(meter.percentText)"
            return meter.isOutdated ? "\(reading), outdated" : reading
        }.joined(separator: ", ")
    }
}
