import AppKit

/// The OpenUsage brand mark (the "liquid U") as a template `NSImage` for the menu bar, drawn from
/// the same bundled SVG as the provider tiles.
@MainActor
enum MenuBarIcon {
    /// Cached template image. Smaller inset than the provider default: the tall U mark should fill
    /// the menu-bar slot about as fully as a system status item glyph.
    static let image: NSImage = ProviderMarks.mark(for: "openusage").fitted(side: 18, inset: 0.08)
}
