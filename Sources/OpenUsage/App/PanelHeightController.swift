import AppKit

/// Owns the menu-bar panel's placement and content-driven height changes. The status-item controller
/// still owns panel creation and show/hide; this type owns only the height boundary between SwiftUI and
/// AppKit.
@MainActor
final class PanelHeightController {
    static let panelWidth: CGFloat = 320
    static let defaultHeight: CGFloat = 800

    private let panel: MenuBarPanel
    private let currentScreen: () -> PopoverScreen
    private let defaults: UserDefaults

    private var anchorScreen: NSScreen?
    private var anchorTopLeft: NSPoint?
    private var morphSettleTask: Task<Void, Never>?
    private(set) var isMorphing = false

    init(
        panel: MenuBarPanel,
        defaults: UserDefaults = .standard,
        currentScreen: @escaping () -> PopoverScreen
    ) {
        self.panel = panel
        self.defaults = defaults
        self.currentScreen = currentScreen
    }

    /// Installs the two narrow callbacks SwiftUI uses: apply one animated frame and clamp a target to
    /// the available display height.
    func installBridge() {
        MenuBarPopover.applyHeight = { [weak self] height in
            self?.applyMorphHeight(height)
        }
        MenuBarPopover.clampHeight = { [weak self] rawHeight in
            self?.clampedHeight(rawHeight) ?? rawHeight
        }
    }

    /// Clears the previous session, captures the display, and opens at the remembered guess. This must
    /// happen before SwiftUI sees the popover as shown, because that signal immediately asks the clamp
    /// hook for this display's real maximum height.
    func prepareForOpening(below buttonRect: NSRect) {
        prepareForOpening(relativeTo: buttonRect, placement: .below)
    }

    /// Side-notch presentation: open the regular dashboard immediately to the left of the edge strip,
    /// vertically centered on it where the display has room. The dashboard stays the same panel and
    /// SwiftUI tree; only its anchor policy changes.
    func prepareForOpening(leftOf notchRect: NSRect) {
        prepareForOpening(relativeTo: notchRect, placement: .left)
    }

    private enum Placement { case below, left }

    private func prepareForOpening(relativeTo anchorRect: NSRect, placement: Placement) {
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()

        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? NSScreen.main
        anchorScreen = screen
        let remembered = loadHeight(for: currentScreen()) ?? Self.defaultHeight
        let topLeft = switch placement {
        case .below:
            PanelGeometry.clampedTopLeft(
                below: anchorRect,
                width: Self.panelWidth,
                visibleFrame: screen?.visibleFrame
            )
        case .left:
            PanelGeometry.clampedTopLeft(
                leftOf: anchorRect,
                width: Self.panelWidth,
                height: remembered,
                visibleFrame: screen?.visibleFrame
            )
        }
        anchorTopLeft = topLeft

        let height = clampedHeight(remembered)
        panel.setFrame(
            PanelGeometry.frame(topLeft: topLeft, width: Self.panelWidth, height: height),
            display: false
        )
        panel.invalidateShadow()
    }

    /// Saves before the caller changes screens or orders the panel out.
    func saveBeforeClosing() {
        guard panel.isVisible else { return }
        saveHeight(panel.frame.height, for: currentScreen())
    }

    /// Clears all opening-session state after the panel is ordered out.
    func finishClosing() {
        anchorTopLeft = nil
        anchorScreen = nil
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()
    }

    private func applyMorphHeight(_ rawHeight: CGFloat) {
        guard rawHeight > 1, panel.isVisible else { return }
        guard let anchorTopLeft else {
            AppLog.error(.statusItem, "Morph height while visible but no anchor; frame not applied")
            return
        }
        let height = clampedHeight(rawHeight)
        guard abs(panel.frame.height - height) > 1 else { return }
        panel.setFrame(
            PanelGeometry.frame(topLeft: anchorTopLeft, width: Self.panelWidth, height: height),
            display: false
        )
        isMorphing = true
        scheduleMorphSettle()
    }

    private func scheduleMorphSettle() {
        morphSettleTask?.cancel()
        morphSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.panel.isVisible else { return }
            self.isMorphing = false
            // Rebuilding the shadow for every interpolated frame competes with the page animation.
            // Refresh it once after the window reaches its final shape instead.
            self.panel.invalidateShadow()
            self.saveHeight(self.panel.frame.height, for: self.currentScreen())
        }
    }

    private func clampedHeight(_ rawHeight: CGFloat) -> CGFloat {
        PanelGeometry.clampedHeight(rawHeight, maximum: maximumHeight())
    }

    private func maximumHeight() -> CGFloat {
        guard let anchorTopLeft, let visibleFrame = (anchorScreen ?? NSScreen.main)?.visibleFrame else {
            return Self.defaultHeight
        }
        return PanelGeometry.maximumHeight(topLeft: anchorTopLeft, visibleFrame: visibleFrame)
    }

    private func loadHeight(for screen: PopoverScreen) -> CGFloat? {
        let value = defaults.double(forKey: Self.heightKey(for: screen))
        return value > 0 ? CGFloat(value) : nil
    }

    private func saveHeight(_ height: CGFloat, for screen: PopoverScreen) {
        defaults.set(Double(height), forKey: Self.heightKey(for: screen))
    }

    private static func heightKey(for screen: PopoverScreen) -> String {
        switch screen {
        case .dashboard: "openusage.panel.height.dashboard"
        case .customize: "openusage.panel.height.customize"
        case .settings: "openusage.panel.height.settings"
        }
    }
}

/// Pure panel geometry, kept separate so display clamping can be tested without opening a window.
enum PanelGeometry {
    static let topGap: CGFloat = 4
    static let screenMargin: CGFloat = 8
    static let minimumHeight: CGFloat = 200

    static func clampedTopLeft(below buttonRect: NSRect, width: CGFloat, visibleFrame: NSRect?) -> NSPoint {
        var x = buttonRect.minX
        if let visibleFrame {
            x = min(
                max(x, visibleFrame.minX + screenMargin),
                visibleFrame.maxX - width - screenMargin
            )
        }
        return NSPoint(x: x, y: buttonRect.minY - topGap)
    }

    /// Top-left origin for a panel opening beside a screen-edge anchor. Both axes clamp to the display:
    /// external displays may sit at negative coordinates, and a tall remembered panel may not fit
    /// centered on a short edge strip.
    static func clampedTopLeft(
        leftOf anchorRect: NSRect,
        width: CGFloat,
        height: CGFloat,
        visibleFrame: NSRect?
    ) -> NSPoint {
        var x = anchorRect.minX - width - topGap
        var y = anchorRect.midY + height / 2
        if let visibleFrame {
            x = min(
                max(x, visibleFrame.minX + screenMargin),
                visibleFrame.maxX - width - screenMargin
            )
            let fittedHeight = min(max(height, minimumHeight), visibleFrame.height - screenMargin * 2)
            y = min(
                max(y, visibleFrame.minY + fittedHeight + screenMargin),
                visibleFrame.maxY - screenMargin
            )
        }
        return NSPoint(x: x, y: y)
    }

    static func maximumHeight(topLeft: NSPoint, visibleFrame: NSRect) -> CGFloat {
        let roomBelowAnchor = topLeft.y - visibleFrame.minY - screenMargin
        let aestheticCap = floor(visibleFrame.height * 0.85)
        return max(1, min(roomBelowAnchor, aestheticCap))
    }

    static func clampedHeight(_ rawHeight: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(rawHeight, minimumHeight), maximum)
    }

    static func frame(topLeft: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            origin: NSPoint(x: topLeft.x, y: topLeft.y - height),
            size: NSSize(width: width, height: height)
        )
    }
}
