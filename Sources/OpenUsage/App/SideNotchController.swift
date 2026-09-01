import AppKit
import Observation
import SwiftUI

/// A non-activating, key-capable panel at the same level as the system menu bar. The side notch stays
/// above normal app windows and accepts its buttons without stealing the frontmost app.
final class SideNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI's ordinary hover tracking can be dropped by an inactive borderless panel. This AppKit view
/// installs one always-active tracking area over the window and reports screen-space pointer movement;
/// provider-frame ownership still stays in SwiftUI.
private final class SideNotchTrackingView: NSView {
    var onMouseLocation: ((CGPoint) -> Void)?
    private var activeTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let activeTrackingArea { removeTrackingArea(activeTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        activeTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { report() }
    override func mouseMoved(with event: NSEvent) { report() }
    override func mouseExited(with event: NSEvent) { report() }

    private func report() {
        onMouseLocation?(NSEvent.mouseLocation)
    }
}

/// Owns the optional screen-edge presentation. SwiftUI renders the provider rings and detail card;
/// this narrow AppKit boundary owns the specialized always-on-top window, display anchoring, and
/// frame changes required to keep its right edge welded to the screen.
@MainActor
final class SideNotchController {
    static let collapsedSize = NSSize(
        width: SideNotchLayout.collapsedWidth,
        height: SideNotchLayout.collapsedHeight
    )
    static let stripWidth = SideNotchLayout.stripWidth
    static let detailSize = NSSize(width: SideNotchLayout.detailWidth, height: SideNotchLayout.maximumHeight)

    private let panel: SideNotchPanel
    private let model = SideNotchViewModel()
    private var screenObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var collapseTask: Task<Void, Never>?
    private var isShown = false

    /// The visible part of the fixed transparent panel. The full window never moves or resizes,
    /// but anchoring and outside-click policy must ignore its transparent area.
    var interactiveFrame: NSRect? {
        guard isShown else { return nil }
        let size = visibleSurfaceSize
        return NSRect(
            x: panel.frame.maxX - size.width,
            y: panel.frame.midY - size.height / 2 + stripVerticalOffset(for: size),
            width: size.width,
            height: size.height
        )
    }

    init(
        container: AppContainer,
        openDashboard: @escaping @MainActor () -> Void,
        openSettings: @escaping @MainActor () -> Void
    ) {
        let panel = SideNotchPanel(
            contentRect: NSRect(origin: .zero, size: Self.detailSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        let root = SideNotchView(
            container: container,
            model: model,
            openDashboard: openDashboard,
            openSettings: openSettings
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.wantsLayer = true
        hosting.view.layerContentsRedrawPolicy = .duringViewResize
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let trackingView = SideNotchTrackingView()
        trackingView.onMouseLocation = { [weak self] screenPoint in
            self?.handlePointer(at: screenPoint)
        }
        trackingView.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: trackingView.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: trackingView.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: trackingView.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: trackingView.bottomAnchor),
        ])

        let rootController = NSViewController()
        rootController.view = trackingView
        rootController.addChild(hosting)
        panel.contentViewController = rootController

        configurePanel()
        observePresentationState()
        // While collapsed the fixed transparent panel ignores mouse events so it never steals clicks
        // from apps underneath. A global mouse-move monitor detects entry into the visible compact handle;
        // expansion then makes the panel interactive for its buttons and context menu.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePointer(at: NSEvent.mouseLocation)
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyFrame()
            }
        }
    }

    func show() {
        guard !isShown else {
            applyFrame()
            return
        }
        isShown = true
        applyFrame()
        panel.ignoresMouseEvents = !model.isExpanded
        panel.orderFrontRegardless()
        AppLog.info(.statusItem, "Side notch shown")
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        collapseTask?.cancel()
        collapseTask = nil
        panel.orderOut(nil)
        model.collapse()
        AppLog.info(.statusItem, "Side notch hidden")
    }

    private func configurePanel() {
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        // SwiftUI's `.onHover` is backed by AppKit mouse-move delivery. Borderless panels do not
        // request those events by default, so the provider detail card would otherwise never open.
        panel.acceptsMouseMovedEvents = true
        panel.hasShadow = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    /// `withObservationTracking` is one-shot. Re-arm after every state change so AppKit follows the
    /// SwiftUI interaction state without moving window ownership into the view tree.
    private func observePresentationState() {
        withObservationTracking {
            _ = model.isExpanded
            _ = model.hoveredProviderID
            _ = model.expandedStripHeight
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panel.ignoresMouseEvents = !self.model.isExpanded
                self.applyFrame()
                self.observePresentationState()
            }
        }
    }

    /// Codenotch keeps one fixed transparent window and moves only its content. Doing the same keeps
    /// the provider strip perfectly welded to the edge when a detail recap appears—there is no window
    /// resize for AppKit and SwiftUI to race over.
    private func applyFrame() {
        guard isShown, let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let size = NSSize(
            width: Self.detailSize.width,
            height: min(Self.detailSize.height, max(Self.collapsedSize.height, screen.frame.height))
        )
        let target = SideNotchGeometry.frame(size: size, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true)
    }

    private var visibleSurfaceSize: NSSize {
        guard model.isExpanded else { return Self.collapsedSize }
        let width = model.hoveredProviderID == nil ? Self.stripWidth : Self.detailSize.width
        return NSSize(width: width, height: model.expandedStripHeight)
    }

    /// SwiftUI lifts Codenotch's expanded rail slightly above the window midpoint. Mirror that offset
    /// in AppKit's hover target while leaving only the collapsed handle centered.
    private func stripVerticalOffset(for size: NSSize) -> CGFloat {
        size == Self.collapsedSize ? 0 : -SideNotchLayout.verticalOffset
    }

    private func handlePointer(at screenPoint: NSPoint) {
        guard isShown else { return }

        if !model.isExpanded {
            guard interactiveFrame?.contains(screenPoint) == true else { return }
            cancelCollapse()
            model.isExpanded = true
            // Let SwiftUI lay out the provider buttons, then resolve the same pointer again. If the
            // handle opened underneath a provider—Codenotch's characteristic interaction—the recap
            // arrives in the same hover without requiring an extra mouse wiggle.
            Task { @MainActor [weak self] in
                await Task.yield()
                await Task.yield()
                self?.handlePointer(at: NSEvent.mouseLocation)
            }
            return
        }

        guard interactiveFrame?.contains(screenPoint) == true else {
            scheduleCollapse()
            return
        }
        cancelCollapse()

        let stripMinX = panel.frame.maxX - Self.stripWidth
        guard screenPoint.x >= stripMinX else { return }
        let topEdgeOffset = panel.frame.maxY - screenPoint.y
        // Preserve the current recap while crossing the visual breathing room between provider rows.
        // Codenotch treats the full rail as one continuous hover target; clearing here caused the card
        // to disappear for a frame before the next provider's crossfade could begin.
        if let providerID = model.provider(atVerticalOffset: topEdgeOffset) {
            model.hoveredProviderID = providerID
        }
    }

    /// A short grace period makes the strip/card handoff forgiving and mirrors Codenotch's `hoverGrace`
    /// behavior. Re-check the live pointer before collapsing so a quick move back never flickers.
    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self else { return }
            self.collapseTask = nil
            guard self.interactiveFrame?.contains(NSEvent.mouseLocation) != true else { return }
            self.model.collapse()
        }
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }
}

/// Pure edge-notch geometry, split out for regression tests and multi-display edge cases.
enum SideNotchGeometry {
    static func frame(size: NSSize, screenFrame: NSRect, visibleFrame _: NSRect) -> NSRect {
        let height = min(size.height, screenFrame.height)
        let y = ceil(min(
            max(screenFrame.midY - height / 2, screenFrame.minY),
            screenFrame.maxY - height
        ))
        return NSRect(
            x: screenFrame.maxX - size.width,
            y: y,
            width: size.width,
            height: height
        )
    }
}
