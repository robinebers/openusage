import SwiftUI

/// Wraps one `Text` onto lines of roughly equal width, the way CSS `text-wrap: balance` does, so a
/// centered message doesn't end in a lone word. Text that fits on one line keeps its natural size;
/// wrapped text gets the narrowest width that still needs no more lines than the width it was offered
/// (found by binary search on the measured height). `maxWidth` caps the width, and stands in for it
/// when none is offered, as when a window sizes itself to fit.
struct BalancedLines: Layout {
    var maxWidth: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let natural = text.sizeThatFits(.unspecified)
        let offered = min(proposal.width ?? .infinity, maxWidth)
        guard offered.isFinite, natural.width > offered else { return natural }
        func height(_ width: CGFloat) -> CGFloat { text.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let lines = height(offered)
        var tooNarrow: CGFloat = 0
        var fits = offered
        while fits - tooNarrow > 1 {
            let mid = (tooNarrow + fits) / 2
            if height(mid) > lines {
                tooNarrow = mid
            } else {
                fits = mid
            }
        }
        return text.sizeThatFits(ProposedViewSize(width: fits.rounded(.up), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = sizeThatFits(proposal: ProposedViewSize(bounds.size), subviews: subviews, cache: &cache)
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
    }
}
