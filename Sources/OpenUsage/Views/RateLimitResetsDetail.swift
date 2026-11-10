import SwiftUI

/// When a `claim` closure is supplied, each usable reset also becomes claimable: hovering its node reveals
/// a "Use" affordance, clicking it expands that node in place into an inline confirm, and confirming spends
/// exactly that row's reset and shows the outcome. `claim` is `nil` for a read-only timeline. Each claim carries
/// an idempotency key (a UUID minted when its row enters confirm and reused for any retry until the claim
/// settles), so a retried claim can never double-spend: the server answers it as already used, which
/// counts as success.
struct RateLimitResetsDetail: View {
    let count: Int
    let expiries: [Date]
    var items: [ResetItem] = []
    var showsActions = false
    var onHoverChange: (Bool) -> Void
    var onPinChange: ((Bool) -> Void)?
    var claim: ((_ item: ResetItem, _ requestID: String) async -> ResetClaimOutcome)?

    @State private var claimed: [ResetClaimRef: Int] = [:]
    @State private var itemsVersion = 0
    @State private var confirming: Entry.Key?
    @State private var claiming: Entry.Key?
    @State private var hovered: Entry.Key?
    @State private var requestIDs: [ResetClaimRef: String] = [:]
    @State private var banner: Banner?
    /// Kinds a claim has shown need no reset right now; their rows' Use stays disabled.
    @State private var nothingToReset: Set<ResetKind> = []

    private static let width: CGFloat = 250

    private var claimInProgress: Bool { confirming != nil || claiming != nil }

    private var content: Content {
        Self.content(count: count, expiries: expiries, items: items, claimed: claimed)
    }

    var body: some View {
        let content = content
        VStack(alignment: .leading, spacing: 8) {
            if let banner {
                bannerView(banner)
                    .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
            }
            if let claiming, !content.entries.contains(where: { $0.key == claiming }) {
                claimingRow().transition(.opacity)
                if case .timeline(let entries) = content {
                    timeline(entries)
                }
            } else {
                switch content {
                case .timeline(let entries): timeline(entries)
                case .unknownExpiries(let count): unknownExpiriesState(count)
                case .empty: emptyState
                }
            }
        }
        .padding(14)
        .frame(width: Self.width)
        // Report the ideal (content-hugging) height as the fixed size, so collapsing the confirm card
        // back to a node shrinks the popover again — without this, NSPopover keeps the largest
        // height it has ever measured (it grows on Use but never scales back on Cancel).
        .fixedSize(horizontal: false, vertical: true)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
        .onChange(of: items) { _, newValue in
            itemsVersion += 1
            claimed = [:]
            dropConfirmUnlisted(Self.content(count: count, expiries: expiries, items: newValue))
        }
        .onChange(of: expiries) { _, newValue in
            guard items.isEmpty else { return }
            dropConfirmUnlisted(Self.content(count: count, expiries: newValue, items: items))
        }
    }

    /// A refresh that takes away the row being confirmed takes its confirmation with it.
    private func dropConfirmUnlisted(_ content: Content) {
        if let confirming, !content.entries.contains(where: { $0.key == confirming }) { cancelConfirm() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("You have no rate limit resets")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func unknownExpiriesState(_ count: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(count) available")
                .font(.callout)
                .foregroundStyle(.primary)
            Text("Expiry times unavailable")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func timeline(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries, id: \.key) { entry in
                let isFirst = entry.id == 0
                let isLast = entry.id == entries.count - 1
                HStack(alignment: .top, spacing: 10) {
                    rail(for: entry, isFirst: isFirst, isLast: isLast, dotCenterY: dotCenterY(for: entry))
                    node(entry)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func dotCenterY(for entry: Entry) -> CGFloat {
        confirming == entry.key ? confirmCardPadding + 9 : firstLineCenterY
    }

    /// The connector rail: a hairline in two segments — a fixed-height top segment (row top → dot
    /// center) and a stretchy bottom segment (dot center → row bottom) — so it runs unbroken through the
    /// dot and, on a tall confirm node, all the way down to the next node. The first node hides its top
    /// segment and the last its bottom (nothing to connect to beyond the ends). Segments, not a
    /// GeometryReader path: `maxHeight: .infinity` rectangles reliably stretch to the row's full height
    /// inside the HStack, where a GeometryReader collapses to its 10pt default and cuts the line short.
    private func rail(for entry: Entry, isFirst: Bool, isLast: Bool, dotCenterY: CGFloat) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(height: dotCenterY)
                    .opacity(isFirst ? 0 : 1)
                Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity)
                    .opacity(isLast ? 0 : 1)
            }
            numberedDot(entry).padding(.top, dotCenterY - 9)
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }

    private func numberedDot(_ entry: Entry) -> some View {
        ZStack {
            Circle().fill(Theme.severityColor(entry.severity)).frame(width: 18, height: 18)
            Text("\(entry.number)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func node(_ entry: Entry) -> some View {
        if confirming == entry.key {
            confirmRow(entry)
                .transition(.scale(scale: 0.95, anchor: .top).combined(with: .opacity))
        } else if claiming == entry.key {
            claimingRow()
                .transition(.opacity)
        } else {
            row(entry)
                .opacity(claimInProgress ? 0.45 : 1)
                .allowsHitTesting(!claimInProgress)
                .transition(.opacity)
        }
    }

    /// A node is two lines: the kind and countdown, then the use-by time. The dot sits on the first line.
    private let nodeTopPadding: CGFloat = 5
    private let firstLineHeight: CGFloat = 20
    private var firstLineCenterY: CGFloat { nodeTopPadding + firstLineHeight / 2 }
    private let confirmCardPadding: CGFloat = 10

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        Group {
            if let item = entry.item {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(item.kind.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        trailing(entry)
                    }
                    .frame(height: firstLineHeight)
                    Text(entry.useBy)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: 15)
                }
                .padding(.top, nodeTopPadding)
                .padding(.bottom, 7)
            } else {
                // The expiries alone, until the provider's list says what each reset is.
                HStack(spacing: 8) {
                    Text(entry.useBy)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    trailing(entry)
                }
                .frame(height: firstLineCenterY * 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = entry.key }
            else if hovered == entry.key { hovered = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityLabel)
    }

    @ViewBuilder
    private func trailing(_ entry: Entry) -> some View {
        Group {
            if let item = usableItem(entry), showsActions || hovered == entry.key, !claimInProgress {
                let blocked = nothingToReset.contains(item.kind)
                Button("Use") { beginConfirm(entry, item) }
                    .controlSize(.small)
                    .disabled(blocked)
                    .hoverTooltip(blocked ? "Nothing to reset right now" : nil)
                    .transition(.opacity)
            } else if let countdown = entry.countdown {
                Text(countdown)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func confirmRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use this reset?")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text(entry.item?.confirmDetail ?? "Immediately reset your usage limits. This can't be undone.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { runClaim(entry) } label: {
                    Text("Reset").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button { cancelConfirm() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(confirmCardPadding)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5))
        }
        .padding(.vertical, 4)
    }

    private func claimingRow() -> some View {
        HStack(spacing: 8) {
            Text("Resetting your usage…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            MotionAwareProgressView(controlSize: .small)
        }
        .frame(height: firstLineCenterY * 2)
    }

    private func bannerView(_ banner: Banner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.icon)
                .font(.system(size: 14))
                .foregroundStyle(banner.tint)
                .accessibilityHidden(true)
            Text(banner.text)
                .font(.callout.weight(.medium))
                .foregroundStyle(banner.tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(banner.tint.opacity(0.12))
        }
    }

    private static let flowAnimation: Animation = .snappy(duration: 0.25)

    private func usableItem(_ entry: Entry) -> ResetItem? {
        guard claim != nil, let item = entry.item, item.usable else { return nil }
        return item
    }

    private func beginConfirm(_ entry: Entry, _ item: ResetItem) {
        if requestIDs[item.claim] == nil { requestIDs[item.claim] = UUID().uuidString }
        withAnimation(Self.flowAnimation) {
            banner = nil
            hovered = nil
            confirming = entry.key
        }
        onPinChange?(true)
    }

    private func cancelConfirm() {
        withAnimation(Self.flowAnimation) {
            confirming = nil
        }
        onPinChange?(false)
    }

    private func runClaim(_ entry: Entry) {
        guard let claim, let item = entry.item else { return }
        let requestID = requestIDs[item.claim] ?? UUID().uuidString
        requestIDs[item.claim] = requestID
        withAnimation(Self.flowAnimation) {
            confirming = nil
            claiming = entry.key
        }
        let versionAtClaim = itemsVersion
        Task {
            let outcome = await claim(item, requestID)
            withAnimation(Self.flowAnimation) {
                claiming = nil
                apply(outcome, for: item, refreshed: itemsVersion != versionAtClaim)
            }
            onPinChange?(false)
        }
    }

    private func apply(_ outcome: ResetClaimOutcome, for item: ResetItem, refreshed: Bool) {
        switch outcome {
        case .success:
            if !refreshed { claimed[item.claim, default: 0] += 1 }
            nothingToReset.insert(item.kind)
        case .nothingToReset:
            nothingToReset.insert(item.kind)
        case .noCredit:
            if !refreshed { claimed[item.claim, default: 0] += 1 }
        case .notNextReset, .unconfirmed, .unavailableNow, .failed:
            break
        }
        // A settled claim's key is done: the next claim on this record is a new one. An unsettled claim
        // keeps its key, so a retry can't spend a second reset.
        switch outcome {
        case .unconfirmed, .failed: break
        case .success, .nothingToReset, .noCredit, .notNextReset, .unavailableNow: requestIDs[item.claim] = nil
        }
        banner = Self.banner(for: outcome)
    }

    static func banner(for outcome: ResetClaimOutcome, now: Date = Date()) -> Banner {
        let text = outcome.message(now: now)
        switch outcome {
        case .success:
            return Banner(text: text, icon: "checkmark.circle.fill", tint: .green)
        case .nothingToReset:
            return Banner(text: text, icon: "info.circle.fill", tint: Theme.severityColor(.normal))
        case .unconfirmed:
            return Banner(text: text, icon: "clock.fill", tint: Theme.severityColor(.normal))
        case .noCredit, .notNextReset, .unavailableNow:
            return Banner(text: text, icon: "exclamationmark.triangle.fill", tint: Theme.severityColor(.warning))
        case .failed:
            return Banner(text: text, icon: "xmark.circle.fill", tint: Theme.severityColor(.critical))
        }
    }

    struct Banner: Equatable {
        let text: String
        let icon: String
        let tint: Color
    }
}
