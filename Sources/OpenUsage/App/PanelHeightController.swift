import AppKit

@MainActor
final class PanelHeightController {
    static let defaultHeight: CGFloat = 800

    private let panel: MenuBarPanel
    private let currentScreen: () -> PopoverScreen
    private let defaults: UserDefaults

    private var anchorScreen: NSScreen?
    private var anchorTopLeft: NSPoint?
    private var morphSettleTask: Task<Void, Never>?
    private(set) var isMorphing = false
    private var contentHeight: CGFloat?
    private var sheetObservers: [NSObjectProtocol] = []

    init(
        panel: MenuBarPanel,
        defaults: UserDefaults = .standard,
        currentScreen: @escaping () -> PopoverScreen
    ) {
        self.panel = panel
        self.defaults = defaults
        self.currentScreen = currentScreen
    }

    func installBridge() {
        MenuBarPopover.applyHeight = { [weak self] height in
            self?.applyMorphHeight(height)
        }
        MenuBarPopover.clampHeight = { [weak self] rawHeight in
            self?.clampedHeight(rawHeight) ?? rawHeight
        }
        let center = NotificationCenter.default
        sheetObservers = [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification].map { name in
            center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                // `attachedSheet` is updated after these notifications, so fit on the next turn.
                Task { @MainActor in self?.fitAttachedSheet() }
            }
        }
        sheetObservers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] note in
            let windowID = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let sheet = self.panel.attachedSheet, windowID == ObjectIdentifier(sheet) else { return }
                self.fitAttachedSheet()
            }
        })
    }

    func prepareForOpening(below buttonRect: NSRect) {
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()

        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
        anchorScreen = screen
        let topLeft = PanelGeometry.clampedTopLeft(
            below: buttonRect,
            width: PanelMetrics.width,
            visibleFrame: screen?.visibleFrame
        )
        anchorTopLeft = topLeft

        let remembered = loadHeight(for: currentScreen()) ?? Self.defaultHeight
        let height = clampedHeight(remembered)
        panel.setFrame(
            PanelGeometry.frame(topLeft: topLeft, width: PanelMetrics.width, height: height),
            display: false
        )
        panel.invalidateShadow()
    }

    func saveBeforeClosing() {
        guard panel.isVisible else { return }
        saveHeight(panel.frame.height, for: currentScreen())
    }

    func finishClosing() {
        anchorTopLeft = nil
        anchorScreen = nil
        contentHeight = nil
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()
    }

    private func fitAttachedSheet() {
        applyMorphHeight(contentHeight ?? panel.frame.height)
    }

    private func applyMorphHeight(_ rawHeight: CGFloat) {
        guard rawHeight > 1, panel.isVisible else { return }
        guard let anchorTopLeft else {
            AppLog.error(.statusItem, "Morph height while visible but no anchor; frame not applied")
            return
        }
        contentHeight = rawHeight
        let height = clampedHeight(PanelGeometry.height(content: rawHeight, attachedSheet: panel.attachedSheet?.frame.height))
        guard abs(panel.frame.height - height) > 1 else { return }
        panel.setFrame(
            PanelGeometry.frame(topLeft: anchorTopLeft, width: PanelMetrics.width, height: height),
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
            self.panel.invalidateShadow()
            self.saveHeight(self.panel.frame.height, for: self.currentScreen())
        }
    }

    private func clampedHeight(_ rawHeight: CGFloat) -> CGFloat {
        min(rawHeight, maximumHeight())
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
        case .accounts: "openusage.panel.height.accounts"
        case .settings: "openusage.panel.height.settings"
        }
    }
}

enum PanelGeometry {
    static let topGap: CGFloat = 4
    static let screenMargin: CGFloat = 8

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

    static func maximumHeight(topLeft: NSPoint, visibleFrame: NSRect) -> CGFloat {
        let roomBelowAnchor = topLeft.y - visibleFrame.minY - screenMargin
        let aestheticCap = floor(visibleFrame.height * 0.85)
        return max(1, min(roomBelowAnchor, aestheticCap))
    }

    static let sheetMargin: CGFloat = 20

    static func height(content: CGFloat, attachedSheet: CGFloat?) -> CGFloat {
        guard let attachedSheet else { return content }
        return max(content, attachedSheet + sheetMargin)
    }

    /// Snaps the top edge and height to whole points. AppKit rounds a window's origin and size
    /// separately, so a half-point status-item anchor plus the morph's fractional heights would land
    /// the top edge on either of two points from frame to frame and visibly shake the panel. The top
    /// rounds down so the gap below the status item never shrinks.
    static func frame(topLeft: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        let top = topLeft.y.rounded(.down)
        let height = height.rounded()
        return NSRect(
            origin: NSPoint(x: topLeft.x, y: top - height),
            size: NSSize(width: width, height: height)
        )
    }
}
