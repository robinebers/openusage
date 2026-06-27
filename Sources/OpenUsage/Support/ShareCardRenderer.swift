import AppKit
import SwiftUI

/// Renders a `ShareCardView` into a PNG and copies it to the clipboard. Mirrors `MenuBarStripRenderer`'s
/// `ImageRenderer` → `cgImage` → `NSImage` path (×4 for a crisp, large export), then PNG-encodes it and
/// writes it to the pasteboard.
@MainActor
enum ShareCardRenderer {
    /// Off-screen render scale. ×4 turns the popover-scale card into a crisp, large PNG — a 360pt card
    /// ships as a 1440px image — without authoring a separate large-format layout.
    static let scale: CGFloat = 4

    /// The card rendered to an `NSImage`, or `nil` if `ImageRenderer` produces no CGImage. The image's
    /// point size is the card's natural (flexible) size; its pixel size is that times `scale`.
    static func image(for view: ShareCardView) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        )
    }

    /// PNG-encodes an `NSImage`, or `nil` if the bitmap can't be formed.
    static func pngData(from image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes the card's PNG onto the general pasteboard (replacing its contents). Beeps and logs if the
    /// PNG can't be encoded or the pasteboard rejects it, so a failed copy isn't silently swallowed.
    static func copyToPasteboard(_ image: NSImage) {
        guard let png = pngData(from: image) else {
            AppLog.error(.lifecycle, "share card: failed to encode PNG for clipboard")
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else {
            AppLog.error(.lifecycle, "share card: pasteboard rejected the PNG")
            NSSound.beep()
            return
        }
    }

    /// Orchestrates a Copy as Image action end to end: resolve the provider's visible rows from the data
    /// store, build the card with the effective appearance, render it, and copy the PNG to the clipboard.
    /// The rows mirror what the dashboard shows — always-shown plus expanded only when the provider's
    /// caret is open — so the export matches what the user sees.
    ///
    /// The render is pinned to the regular density regardless of the user's popover density slider: the
    /// rows read density via `@AppStorage`, so the saved value is swapped to `.regular` for the duration
    /// of the render and restored on exit (synchronously), keeping the exported card consistent without
    /// disturbing the live popover.
    static func share(
        group: ProviderGroup,
        dataStore: WidgetDataStore,
        layout: LayoutStore,
        appearance: ColorScheme
    ) {
        let isExpanded = layout.isProviderExpanded(group.provider.id)
        let alwaysRows = group.alwaysShownWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return dataStore.data(for: descriptor)
        }
        let expandedRows = group.expandedWidgets.compactMap { widget -> WidgetData? in
            guard let descriptor = layout.descriptor(for: widget) else { return nil }
            return dataStore.data(for: descriptor)
        }
        let rows = isExpanded ? alwaysRows + expandedRows : alwaysRows
        let view = ShareCardView(
            provider: group.provider,
            plan: dataStore.plan(for: group.provider.id),
            rows: rows,
            appearance: appearance,
            expandBoundaryIndex: isExpanded ? alwaysRows.count : nil
        )
        let densityKey = DensitySetting.key
        let savedDensity = UserDefaults.standard.string(forKey: densityKey)
        UserDefaults.standard.set(DensitySetting.regular.rawValue, forKey: densityKey)
        defer {
            if let savedDensity {
                UserDefaults.standard.set(savedDensity, forKey: densityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: densityKey)
            }
        }
        guard let image = image(for: view) else {
            AppLog.error(.lifecycle, "share card: ImageRenderer produced no image for \(group.provider.id)")
            NSSound.beep()
            return
        }
        copyToPasteboard(image)
    }
}
