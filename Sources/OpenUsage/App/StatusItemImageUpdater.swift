import AppKit
import Observation

/// Owns the menu-bar strip's render loop, split out of `StatusItemController`: render the pinned-metrics
/// strip and re-render whenever anything it reads changes (pins, live data, meter style, menu-bar style).
///
/// `withObservationTracking`'s `onChange` is one-shot, so each render re-arms it. After the first change,
/// the next render waits briefly so a burst of snapshot writes collapses into one render with the latest
/// values — avoiding enough repeated work to make the menu-bar item disappear during a busy refresh.
/// Unchanged memoized images are not re-applied: setting the same `NSImage` still costs a WindowServer
/// redraw.
@MainActor
final class StatusItemImageUpdater {
    /// Applies a status-item image only when the instance changed. The renderer memoizes by content,
    /// so an identical instance means the button already shows this render — an unconditional set
    /// still costs a full status-item redraw through WindowServer on macOS 26+.
    struct ApplyGate {
        private var lastApplied: NSImage?

        mutating func apply(_ image: NSImage, using apply: (NSImage) -> Void) {
            guard image !== lastApplied else { return }
            lastApplied = image
            apply(image)
        }
    }

    private let container: AppContainer
    private let apply: (NSImage) -> Void
    private var applyGate = ApplyGate()

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
        applyGate.apply(image, using: apply)
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
        let content = MenuBarContentBuilder.build(
            groups: container.layout.pinnedGroups,
            data: { container.dataStore.data(for: $0) }
        )
        return MenuBarStripRenderer.image(for: content) ?? MenuBarIcon.image
    }
}
