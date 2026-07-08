import SwiftUI

/// A small, auto-dismissing confirmation/notice capsule — the "Copied to clipboard" share pill and the
/// Customize action notice. `trigger` is a monotonic counter the caller bumps to re-pop the pill (its
/// `.id` change replays the scale+fade transition even when the text is unchanged). Shared so the
/// capsule styling lives in one place.
struct TransientPill: View {
    let systemImage: String
    let text: String
    let tint: AnyShapeStyle
    /// Bumped by the caller each time the pill is (re-)shown, so `.id` re-pops the transition.
    let trigger: Int
    /// The Dashboard share pill floats over scroll content and carries a drop shadow; the Customize
    /// notice pill sits inline and never had one. Defaults to the shadowed look.
    var showsShadow = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(showsShadow ? 0.12 : 0), radius: 6, y: 2)
        .id(trigger)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}
