import AppKit
import Observation

/// Owns the menu-bar strip's render loop, split out of `StatusItemController`: render the pinned-metrics
/// strip and re-render whenever anything it reads changes (pins, live data, meter style, menu-bar style).
///
/// `withObservationTracking`'s `onChange` is one-shot, so each render re-arms it. After the first change,
/// the next render waits briefly so a burst of snapshot writes collapses into one render with the latest
/// values — avoiding enough repeated work to make the menu-bar item disappear during a busy refresh.
@MainActor
final class StatusItemImageUpdater {
    private let container: AppContainer
    private let apply: (NSImage) -> Void

    /// - Parameter apply: sets the rendered image onto the status-item button.
    init(container: AppContainer, apply: @escaping (NSImage) -> Void) {
        self.container = container
        self.apply = apply
    }

    /// Render now and re-arm on the next observable change.
    func update() {
        let image = withObservationTracking {
            renderButtonImage()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDelayedUpdate()
            }
        }
        apply(image)
    }

    /// The observation callback fires only once until `update()` reads and re-arms it. Waiting here lets
    /// any immediately-following writes land first; the eventual render then reads their latest values.
    private func scheduleDelayedUpdate() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// The pinned-metrics strip in the chosen style, or the app icon when nothing is pinned.
    private func renderButtonImage() -> NSImage {
        // Screen-share privacy: while a capture is active (and the setting is on), the strip is
        // replaced with the wordmark so a shared screen never carries usage numbers. Read inside the
        // observation closure so the render re-arms on capture-state changes too.
        if container.privacy.concealUsage {
            return MenuBarStripRenderer.privacyImage
                ?? MenuBarIcon.image
                ?? MenuBarStripRenderer.fallbackIcon
        }
        let content = MenuBarContentBuilder.build(
            groups: container.layout.pinnedGroups,
            data: { container.dataStore.data(for: $0) },
            title: { container.displayName(for: $0) }
        )
        return MenuBarStripRenderer.image(for: content, style: container.layout.menuBarStyle)
            ?? MenuBarIcon.image
            ?? MenuBarStripRenderer.fallbackIcon
    }
}
