import Observation
import OpenUsageWidgetSupport
import WidgetKit

/// Re-arms observation over exactly the state used to build the desktop-widget payload and asks
/// WidgetKit for a new timeline only when that payload changes. The short debounce collapses a batch
/// of provider refreshes into one system reload request.
@MainActor
final class DesktopWidgetReloader {
    private let snapshot: () -> DesktopWidgetSnapshot
    private var lastSnapshot: DesktopWidgetSnapshot?
    private var reloadTask: Task<Void, Never>?

    init(snapshot: @escaping () -> DesktopWidgetSnapshot) {
        self.snapshot = snapshot
        update()
    }

    deinit {
        reloadTask?.cancel()
    }

    private func update() {
        let next = withObservationTracking {
            snapshot()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
            }
        }
        guard next != lastSnapshot else { return }
        lastSnapshot = next
        scheduleReload()
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: DesktopUsageWidgetKind.value)
        }
    }
}
