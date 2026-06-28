import AppKit

/// The popover panel's backdrop: two full-frame layers built once and switched by visibility.
///
/// `.opaque` shows a solid `NSBox` (the `Theme.trayNSColor` tray) so the data region never reveals the
/// desktop — the app's default look. `.translucent` shows a behind-window `NSVisualEffectView` that
/// samples the desktop with vibrancy, which is the HIG-correct way to "increase transparency" (SwiftUI
/// `glassEffect`/`Material` only sample in-app content, so they can't show the desktop).
///
/// Both children are permanent and pinned to the full frame: rebuilding on toggle would race the
/// observer that drives the mode, and a partial frame could reveal a transparent strip during the
/// panel's height morph. The mode switch is an **alpha crossfade** (both layers stay mounted, one fades
/// out as the other fades in) so enabling/disabling the egg eases rather than snaps. The vibrancy view
/// carries a stretchable rounded `maskImage` because behind-window blur is composited by the window
/// server and doesn't reliably honor a parent layer's corner masking.
final class PopoverBackdropView: NSView {
    enum Mode { case opaque, translucent }

    private let opaqueBox = NSBox()
    private let vibrancy = NSVisualEffectView()
    private var currentMode: Mode = .opaque

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        opaqueBox.boxType = .custom
        opaqueBox.titlePosition = .noTitle
        opaqueBox.borderWidth = 0
        opaqueBox.cornerRadius = cornerRadius
        opaqueBox.contentViewMargins = .zero
        opaqueBox.fillColor = Theme.trayNSColor
        opaqueBox.wantsLayer = true                 // layer-backed so alphaValue animates
        opaqueBox.translatesAutoresizingMaskIntoConstraints = false

        vibrancy.material = .popover
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.maskImage = Self.roundedMaskImage(cornerRadius: cornerRadius)
        vibrancy.wantsLayer = true
        vibrancy.alphaValue = 0                      // starts hidden; opaque tray is the default look
        vibrancy.translatesAutoresizingMaskIntoConstraints = false

        // The opaque box sits above the vibrancy view so the default look fully covers it; only one is
        // ever visible at a time, so the order is just defensive.
        addSubview(vibrancy)
        addSubview(opaqueBox, positioned: .above, relativeTo: vibrancy)
        NSLayoutConstraint.activate([
            vibrancy.leadingAnchor.constraint(equalTo: leadingAnchor),
            vibrancy.trailingAnchor.constraint(equalTo: trailingAnchor),
            vibrancy.topAnchor.constraint(equalTo: topAnchor),
            vibrancy.bottomAnchor.constraint(equalTo: bottomAnchor),
            opaqueBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            opaqueBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            opaqueBox.topAnchor.constraint(equalTo: topAnchor),
            opaqueBox.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Crossfades to the given backdrop layer. Driven by `StatusItemController` from the transparency
    /// style; pass `animated: false` for the initial state so launch doesn't fade in. When `animated`,
    /// the caller wraps this in the same `NSAnimationContext` group as the window-alpha change so they
    /// ease together.
    func setMode(_ mode: Mode, animated: Bool) {
        guard mode != currentMode else { return }
        currentMode = mode
        let opaqueAlpha: CGFloat = mode == .opaque ? 1 : 0
        let vibrancyAlpha: CGFloat = mode == .opaque ? 0 : 1
        if animated {
            opaqueBox.animator().alphaValue = opaqueAlpha
            vibrancy.animator().alphaValue = vibrancyAlpha
        } else {
            opaqueBox.alphaValue = opaqueAlpha
            vibrancy.alphaValue = vibrancyAlpha
        }
    }

    /// A stretchable rounded-rectangle mask: a small rounded square whose cap insets equal the corner
    /// radius, so AppKit tiles the flat center and keeps crisp corners at any size.
    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let side = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                       bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
