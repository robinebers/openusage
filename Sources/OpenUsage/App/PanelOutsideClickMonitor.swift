import AppKit

/// Owns the local and global mouse monitors that dismiss the menu-bar panel.
@MainActor
final class PanelOutsideClickMonitor {
    private let panel: MenuBarPanel
    private let statusItem: NSStatusItem
    private let isMorphing: () -> Bool
    private let onInsidePanelClick: () -> Void
    private let onDismiss: () -> Void
    private var monitors: [Any] = []

    init(
        panel: MenuBarPanel,
        statusItem: NSStatusItem,
        isMorphing: @escaping () -> Bool,
        onInsidePanelClick: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.panel = panel
        self.statusItem = statusItem
        self.isMorphing = isMorphing
        self.onInsidePanelClick = onInsidePanelClick
        self.onDismiss = onDismiss
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // NSEvent is not Sendable, so only copy these small values before returning to the main actor.
            let windowID = event.window.map(ObjectIdentifier.init)
            let windowTypeName = event.window.map { String(describing: type(of: $0)) }
            MainActor.assumeIsolated {
                self?.handleClick(
                    windowID: windowID,
                    windowTypeName: windowTypeName,
                    screenPoint: NSEvent.mouseLocation
                )
            }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // Read the location now; the pointer may move before the main-actor task runs.
            let screenPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleClick(windowID: nil, windowTypeName: nil, screenPoint: screenPoint)
            }
        }) {
            monitors.append(global)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }

    private func handleClick(
        windowID: ObjectIdentifier?,
        windowTypeName: String?,
        screenPoint: NSPoint
    ) {
        let isInsidePanel = panel.frame.contains(screenPoint)
        let hasWindowContext = windowID != nil && windowTypeName != nil
        let buttonWindowID = statusItem.button?.window.map(ObjectIdentifier.init)
        let context = PanelOutsideClickContext(
            isMorphing: isMorphing(),
            hasAttachedSheet: panel.attachedSheet != nil,
            isOnStatusButton: isOnStatusButton(screenPoint),
            isInsidePanel: isInsidePanel,
            isPanelWindow: hasWindowContext && windowID == ObjectIdentifier(panel),
            isStatusItemWindow: hasWindowContext && windowID == buttonWindowID,
            eventWindowTypeName: hasWindowContext ? windowTypeName : nil
        )

        if PanelOutsideClickPolicy.shouldKeepOpen(context) {
            if isInsidePanel { onInsidePanelClick() }
            return
        }
        onDismiss()
    }

    private func isOnStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem.button, let buttonWindow = button.window else { return false }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return PanelOutsideClickPolicy.pointHitsStatusButton(screenPoint, buttonFrame: buttonFrame)
    }
}

struct PanelOutsideClickContext {
    var isMorphing = false
    var hasAttachedSheet = false
    var isOnStatusButton = false
    var isInsidePanel = false
    var isPanelWindow = false
    var isStatusItemWindow = false
    var eventWindowTypeName: String?
}

enum PanelOutsideClickPolicy {
    static func shouldKeepOpen(_ context: PanelOutsideClickContext) -> Bool {
        context.isMorphing
            || context.hasAttachedSheet
            || context.isOnStatusButton
            || context.isInsidePanel
            || context.isPanelWindow
            || context.isStatusItemWindow
            || context.eventWindowTypeName?.localizedCaseInsensitiveContains("menu") == true
            // A hover popover (model breakdown, usage trend, resets timeline) is its own window that
            // floats *outside* the panel frame, so a click on an interactive control inside it — e.g.
            // the resets "Use" button — otherwise reads as an outside click and tears the panel down
            // before the control's mouse-up fires. Its backing window class is `_NSPopoverWindow`.
            || context.eventWindowTypeName?.localizedCaseInsensitiveContains("popover") == true
    }

    /// Status-button hit test with *inclusive* frame edges, unlike `NSRect.contains` (which excludes
    /// the max edges). With the cursor slammed against the top of the screen — the natural way to
    /// click the menu bar — `NSEvent.mouseLocation.y` is exactly the screen's `maxY`, which is also
    /// the button frame's `maxY`. The exclusive check misread that dead-center click as an outside
    /// click, so the panel dismissed on mouse-down and the button's mouse-up action toggled it right
    /// back open — the second click never closed it (issue #1008).
    static func pointHitsStatusButton(_ point: NSPoint, buttonFrame: NSRect) -> Bool {
        guard !buttonFrame.isEmpty else { return false }
        return point.x >= buttonFrame.minX && point.x <= buttonFrame.maxX
            && point.y >= buttonFrame.minY && point.y <= buttonFrame.maxY
    }
}
