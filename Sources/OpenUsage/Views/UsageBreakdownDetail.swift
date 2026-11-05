import SwiftUI

/// A history row's hover detail, and what its copy button puts on the clipboard.
struct UsageBreakdownDetail: View {
    enum Content {
        case reported(UsageBreakdown)
        case saved(UsageWindow, figures: [String], status: AccountStatus, date: Date?)
    }

    let content: Content
    let provider: Provider
    var animates = true
    var onCopy: (UsageBreakdown, ModelFigure) -> Bool
    var onHoverChange: (Bool) -> Void

    @AppStorage(ModelFigure.key) private var figure = ModelFigure.cost
    @State private var copied = false

    static let width: CGFloat = 288
    static let padding: CGFloat = 14

    var body: some View {
        detail
            .padding(Self.padding)
            .frame(width: Self.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topTrailing) {
                if case .reported(let breakdown) = content, !breakdown.isEmpty {
                    CopyFeedbackButton(accessibilityLabel: "Copy \(breakdown.archivedTitle() ?? breakdown.window.title) Usage", copied: $copied, action: { onCopy(breakdown, figure) })
                        .padding(4)
                        .background(Theme.controlFill, in: Circle())
                        .padding(10)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: onHoverChange(true)
                case .ended: onHoverChange(false)
                }
            }
    }

    @ViewBuilder
    private var detail: some View {
        switch content {
        case .reported(let breakdown):
            UsageBreakdownContent(breakdown: breakdown, provider: provider, figure: figure, onPickFigure: { figure = $0 }, animates: animates)
        case let .saved(window, figures, status, date):
            let saved = date.map { "Saved \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Saved Total"
            VStack(alignment: .leading, spacing: 14) {
                UsageSummary(title: "\(window.title) · \(saved)", figures: figures)
                if status.refreshing {
                    HStack(spacing: 6) {
                        MotionAwareProgressView(controlSize: .small)
                        Text("Loading Breakdown…")
                    }
                    .font(.callout)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Breakdown Unavailable")
                            .font(.callout.weight(.medium))
                        Text(status.notice ?? status.staleness ?? "Refresh to load the details for this range.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct UsageBreakdownContent: View {
    let breakdown: UsageBreakdown
    let provider: Provider
    let figure: ModelFigure
    /// Leave it out where nothing can be clicked, as in a picture, and the switch isn't drawn.
    var onPickFigure: ((ModelFigure) -> Void)?
    var animates = false

    /// The stored choice, unless this range can't show it.
    private var shownFigure: ModelFigure {
        breakdown.modelFigures.contains(figure) ? figure : breakdown.modelFigures.first ?? figure
    }

    var body: some View {
        if breakdown.isEmpty {
            nothingToShow
        } else {
            details
        }
    }

    private var title: some View {
        Text(breakdown.archivedTitle() ?? breakdown.window.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var nothingToShow: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
            VStack(spacing: 0) {
                ProviderIcon(id: provider.icon, side: 24, inset: 0.04)
                    .phaseAnimator(animates ? [0.5, 0.2] : [0.5]) { mark, opacity in
                        mark.opacity(opacity)
                    } animation: { _ in
                        .easeInOut(duration: 2.8)
                    }
                    .frame(height: 56)
                    .accessibilityHidden(true)
                    .padding(.bottom, 12)
                BalancedLines {
                    Text("\(provider.displayName) didn't report any data for this range.")
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            UsageSummary(title: breakdown.archivedTitle() ?? breakdown.window.title, figures: breakdown.figures)
            if !breakdown.tokenParts.isEmpty {
                TokenMix(parts: breakdown.tokenParts, fillsTotal: breakdown.tokenPartsFillTotal)
            }
            if !breakdown.modelFigures.isEmpty {
                topModels
            }
        }
    }

    private var topModels: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Top Models")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let onPickFigure, breakdown.modelFigures.count > 1 {
                    CapsuleSegments(
                        options: breakdown.modelFigures.map { ($0, $0.label) },
                        selection: Binding(get: { shownFigure }, set: onPickFigure),
                        height: 22,
                        fontSize: 11,
                        segmentWidth: 48
                    )
                    .fixedSize()
                }
            }
            VStack(spacing: 2) {
                ForEach(breakdown.models(by: shownFigure), id: \.name) { model in
                    HStack(spacing: 8) {
                        Text(model.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if let number = model.number(shownFigure) {
                            Text(shownFigure.text(number))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 12))
                    .frame(minHeight: 18)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct UsageSummary: View {
    let title: String
    let figures: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let headline = figures.first {
                Text(headline)
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if figures.count > 1 {
                Text(figures.dropFirst().joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }
}

/// The kinds of token in a window, in a bar when they add up to its total.
private struct TokenMix: View {
    let parts: [UsageBreakdown.TokenPart]
    let fillsTotal: Bool

    private static let shades: [Double] = [1, 0.6, 0.35, 0.2, 0.12]

    private func color(_ index: Int) -> Color {
        Theme.severityColor(.normal).opacity(Self.shades[min(index, Self.shades.count - 1)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if fillsTotal { bar }
            HStack(alignment: .top, spacing: 8) {
                let split = (parts.count + 1) / 2
                legend(0..<split)
                Spacer(minLength: 0)
                legend(split..<parts.count)
            }
        }
    }

    private var bar: some View {
        let total = parts.reduce(0) { $0 + $1.number }
        return GeometryReader { proxy in
            let room = proxy.size.width - CGFloat(parts.count - 1)
            HStack(spacing: 1) {
                ForEach(parts.indices, id: \.self) { index in
                    color(index).frame(width: max(1, room * parts[index].number / total))
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    /// Sized to its widest row, so the names and numbers of both columns always fit whole.
    private func legend(_ indices: Range<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(indices, id: \.self) { index in
                HStack(spacing: 0) {
                    Circle().fill(color(index)).frame(width: 6, height: 6)
                        .padding(.trailing, 6)
                    Text(parts[index].title)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(MetricFormatter.number(parts[index].number, kind: .count, style: .row))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .fixedSize()
    }
}
