import AppKit
import SwiftUI

/// The dashboard footer's trailing control: a single **Options ⌄** menu button in Liquid Glass, one
/// tap target holding one menu: Accounts / Settings / Report an Issue / About / Quit. Accounts leads
/// because it's the screen users reach for most; Settings stays one click away (and always via ⌘,).
///
/// The capsule is a `.buttonStyle(.plain)` `Menu` with one `interactiveGlass(in: Capsule())` treatment
/// behind it — the system `.buttonStyle(.glass)` renders flat on a `Menu` (its own button chrome wins),
/// so the treatment goes on the container; macOS 15 draws a frosted capsule instead. The menu renders
/// in its own `NSMenu`-backed window, which the panel's outside-click policy keeps the popover open for.
///
/// Only the dashboard shows this; the Accounts and Settings screens carry their own top-leading back
/// button (`PopoverTopBar`) to return home — the macOS-native place for it — so the footer control
/// simply drops away there.
///
/// Shortcuts survive: ⌘, (Settings), ⏎ (Accounts) and Esc are handled by the always-on
/// `PopoverKeyReader` monitor, so they fire from every screen (including Settings, whose footer shows
/// only the identity line — no actions). The menu items only carry their ⌘ key-equivalents as labels
/// and fire while the menu is open, so the monitor and the items never double-fire. ⌘Q (Quit) is
/// unowned elsewhere, so it rides its menu item directly.
struct HeaderView: View {
    @Environment(LayoutStore.self) private var layout
    /// The screen this footer belongs to — each page carries its own — so the control shows on the
    /// dashboard and slides away with it.
    let screen: PopoverScreen

    /// Control height, so the capsule matches the footer's other chrome.
    private static let controlHeight: CGFloat = 28

    var body: some View {
        leadingControl
    }

    /// On the dashboard, the Options menu button on one glass capsule.
    @ViewBuilder
    private var leadingControl: some View {
        if screen == .dashboard {
            optionsButton
                .fixedSize()
                .interactiveGlass(in: Capsule())
        }
    }

    /// The Options pull-down: label plus its own chevron glyph. `.menuStyle(.button)` +
    /// `.buttonStyle(.plain)` strip the menu chrome so `interactiveGlass` owns the surface;
    /// `.menuIndicator(.hidden)` drops the built-in arrow in favor of our styled chevron.
    private var optionsButton: some View {
        Menu {
            menuItems
        } label: {
            HStack(spacing: 5) {
                Text("Options")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: Self.controlHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// The menu's items, mirroring their in-popover entry points. Accounts leads, then Settings.
    /// Accounts and Settings carry their key equivalents so the menu shows the shortcuts: when the
    /// menu is open the items handle them; when it's closed the `PopoverKeyReader` monitor handles
    /// (and consumes) them first, so the equivalents can't double-fire. Same split as the Quit ⌘Q
    /// item below.
    @ViewBuilder
    private var menuItems: some View {
        Button { toggle(.accounts) } label: {
            Label("Accounts", systemImage: "person.crop.circle")
        }
        .keyboardShortcut(.return, modifiers: [])

        Button { toggle(.settings) } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Divider()

        Link(destination: URL(string: "https://github.com/robinebers/openusage/issues/new/choose")!) {
            Label("Report an Issue…", systemImage: "ladybug")
        }

        Button { AboutPanel.present() } label: {
            Label("About OpenUsage", systemImage: "info.circle")
        }
        Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
            Label("Quit OpenUsage", systemImage: "power")
        }
        .keyboardShortcut("q") // ⌘Q — unowned elsewhere, so safe to register on the item.
    }

    private func toggle(_ screen: PopoverScreen) {
        withAnimation(Motion.modeSwitch) {
            layout.screen = layout.screen == screen ? .dashboard : screen
        }
    }
}
