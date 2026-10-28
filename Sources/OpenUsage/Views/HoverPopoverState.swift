import Foundation

@MainActor
@Observable
final class HoverPopoverState {
    var isPresented = false

    /// Every live coordinator, so the menu-bar panel's close path can dismiss any open hover popover —
    /// the dashboard view tree (and this `@State`) survives the panel's `orderOut`, so `.onDisappear`
    /// alone wouldn't fire and the popover could orphan or re-show on the next open.
    @ObservationIgnored private static let live = NSHashTable<HoverPopoverState>.weakObjects()

    static func dismissAll() {
        for state in live.allObjects { state.dismiss() }
    }

    private(set) var overInline = false
    @ObservationIgnored private var overDetail = false
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    private let revealDelay: Duration
    private let hideGrace: Duration

    init(revealDelay: Duration = .milliseconds(400), hideGrace: Duration = .milliseconds(180)) {
        self.revealDelay = revealDelay
        self.hideGrace = hideGrace
        Self.live.add(self)
    }

    func inlineHover(_ active: Bool) {
        if overInline != active { overInline = active }
        active ? scheduleShow() : scheduleHide()
    }

    func detailHover(_ inside: Bool) {
        overDetail = inside
        if inside { hideTask?.cancel(); hideTask = nil } else { scheduleHide() }
    }

    func setPinned(_ active: Bool) {
        guard pinned != active else { return }
        pinned = active
        if active { hideTask?.cancel(); hideTask = nil } else { scheduleHide() }
    }

    func dismiss() {
        showTask?.cancel(); showTask = nil
        hideTask?.cancel(); hideTask = nil
        overInline = false
        overDetail = false
        pinned = false
        isPresented = false
    }

    private func scheduleShow() {
        hideTask?.cancel(); hideTask = nil
        guard !isPresented, showTask == nil else { return }
        let delay = revealDelay
        showTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if overInline { isPresented = true }
            showTask = nil
        }
    }

    private func scheduleHide() {
        guard !pinned else { return }
        showTask?.cancel(); showTask = nil
        hideTask?.cancel()
        let delay = hideGrace
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if !overInline, !overDetail, !pinned { isPresented = false }
            hideTask = nil
        }
    }
}
