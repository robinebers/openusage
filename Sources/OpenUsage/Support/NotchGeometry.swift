import AppKit

/// Pure notch-occlusion geometry, kept separate so it can be tested without a real screen
/// (mirrors `PanelGeometry`).
///
/// On notched MacBooks, macOS lays status items out right-to-left; when the menu bar fills up,
/// the leftmost third-party items are pushed under the notch. The item still exists — AppKit
/// reports a live button and "Status item ready" is logged — but it is invisible and unclickable,
/// so the app looks like it never launched. There is no API to reposition a status item (its x is
/// determined by the neighbors to its right), so these helpers only *detect* that state; callers
/// provide the visible escape hatch (an edge-anchored panel, a surrogate pill).
enum NotchGeometry {
    /// How a status-item button (in screen coordinates) is occluded by the notch.
    struct Occlusion: Equatable {
        enum Edge: Equatable {
            case left
            case right
        }

        /// Fraction of the rect's width hidden behind the notch, in (0…1].
        let hiddenFraction: CGFloat
        /// The notch edge closest to the rect's center — the nearest place something can be seen.
        let nearestVisibleEdge: Edge
        /// X of that edge in screen coordinates (the notch's `minX` or `maxX`).
        let nearestVisibleEdgeX: CGFloat

        /// True when so little of the rect remains visible that it is effectively undiscoverable.
        /// 0.75 keeps a half-covered (still findable, still clickable) item out of fallback mode;
        /// the measured real-world cases are 0.86 (text strip) and 1.0 (bars glyph).
        var isEffectivelyHidden: Bool { hiddenFraction >= 0.75 }
    }

    /// The notch rect in screen coordinates, or `nil` when the screen has no notch.
    static func notchRect(of screen: NSScreen) -> NSRect? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return nil
        }
        return notchRect(auxiliaryTopLeft: left, auxiliaryTopRight: right, screenFrame: screen.frame)
    }

    /// The gap between the two auxiliary menu-bar areas, extended to the top of the screen.
    static func notchRect(
        auxiliaryTopLeft left: NSRect,
        auxiliaryTopRight right: NSRect,
        screenFrame: NSRect
    ) -> NSRect? {
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        let minY = min(left.minY, right.minY)
        return NSRect(x: left.maxX, y: minY, width: width, height: screenFrame.maxY - minY)
    }

    /// How much of `rect` the notch hides, or `nil` when they don't intersect.
    static func occlusion(of rect: NSRect, notch: NSRect) -> Occlusion? {
        let overlap = rect.intersection(notch)
        guard rect.width > 0, !overlap.isNull, overlap.width > 0 else { return nil }
        let nearestEdge: Occlusion.Edge =
            abs(rect.midX - notch.minX) <= abs(rect.midX - notch.maxX) ? .left : .right
        return Occlusion(
            hiddenFraction: overlap.width / rect.width,
            nearestVisibleEdge: nearestEdge,
            nearestVisibleEdgeX: nearestEdge == .left ? notch.minX : notch.maxX
        )
    }

    /// Where `showPanel` should anchor instead of the hidden button: at the nearest visible notch
    /// edge, sided so the panel opens away from the notch (left edge → the panel's right edge meets
    /// it; right edge → the panel's left edge meets it). Y is carried over from the button so the
    /// panel still hangs from the menu bar.
    static func panelAnchorRect(
        for occlusion: Occlusion,
        buttonRect: NSRect,
        panelWidth: CGFloat
    ) -> NSRect {
        let x: CGFloat = switch occlusion.nearestVisibleEdge {
        case .left: occlusion.nearestVisibleEdgeX - panelWidth
        case .right: occlusion.nearestVisibleEdgeX
        }
        return NSRect(x: x, y: buttonRect.minY, width: buttonRect.width, height: buttonRect.height)
    }
}
