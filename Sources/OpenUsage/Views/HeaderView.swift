import AppKit
import SwiftUI

/// The dashboard footer's trailing control: a **split button** in Liquid Glass — one capsule with
/// "Settings" on the left and a chevron segment on the right, divided by a hairline (the Export ▾
/// idiom system apps use). Clicking "Settings" opens the Settings screen; clicking the chevron opens
/// the overflow menu (Customize / Check for Updates / About / Quit). Settings leads because everyday
/// layout edits (reorder, hide, pin) are already reachable by dragging and right-clicking on the
/// dashboard itself, so Settings is the more frequent deliberate destination.
///
/// The joined-capsule look comes from one glass surface behind the *whole* control: an `HStack` of two
/// `.buttonStyle(.plain)` tap targets (a `Button` and a chevron `Menu`) split by a `Divider`, with a
/// single `interactiveGlass(in: Capsule())` drawn behind all of it. Glass goes on the container, not
/// each segment — per-segment glass would split it into two pills, and the system `.buttonStyle(.glass)`
/// renders flat on a `Menu` (its own button chrome wins). This is the canonical macOS 26 pattern
/// (custom `glassEffect` surface behind grouped controls); it falls back to a frosted material capsule
/// on macOS 15. The menu renders in its own `NSMenu`-backed window, which
/// `StatusItemController.shouldKeepPanelOpen` keeps the popover open for.
///
/// Only the dashboard shows this; the Customize and Settings screens carry their own top-leading back
/// button (`DashboardView.navBar`) to return home — the macOS-native place for it — so the footer
/// control simply drops away there.
///
/// Shortcuts survive: ⌘, (Settings), ⏎ (Customize) and Esc are handled by the always-on
/// `PopoverKeyReader` monitor, so they fire from every screen (including Settings, whose footer shows
/// only the identity line — no buttons). The menu items only carry their ⌘ key-equivalents as labels
/// and fire while the menu is open, so the monitor and the items never double-fire. ⌘Q (Quit) is
/// unowned elsewhere, so it rides its menu item directly.
struct HeaderView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(UpdaterController.self) private var updater
    /// The current screen. The footer is fixed chrome keyed off `layout.screen` (it no longer slides
    /// per-page), so this control shows only when that's `.dashboard` and swaps in place on a switch.
    let screen: PopoverScreen

    /// Shared height for both halves, so the capsule reads as one control.
    private static let controlHeight: CGFloat = 28

    var body: some View {
        leadingControl
    }

    /// On the dashboard, the split button: the two halves laid out edge to edge (spacing 0) with a
    /// hairline `Divider` between, all on one glass capsule.
    @ViewBuilder
    private var leadingControl: some View {
        if screen == .dashboard {
            HStack(spacing: 0) {
                settingsHalf
                Divider()
                    .frame(height: 16)
                chevronHalf
            }
            .fixedSize()
            .interactiveGlass(in: Capsule())
        }
    }

    /// Left half: opens Settings. `.buttonStyle(.plain)` strips the system chrome so the shared glass
    /// is the only surface; `contentShape` makes the whole padded half clickable. ⌘, opens Settings
    /// from anywhere via `PopoverKeyReader`, so the shortcut isn't registered here (which would also
    /// flag the button as the window's default and draw a pulsing ring) — the tooltip surfaces it.
    private var settingsHalf: some View {
        Button { toggle(.settings) } label: {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 14)
                .padding(.trailing, 11)
                .frame(height: Self.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip("Settings (⌘,)")
    }

    /// Right half: the chevron pull-down. `.menuStyle(.button)` + `.buttonStyle(.plain)` strip the menu
    /// chrome to just the glyph; `.menuIndicator(.hidden)` drops the built-in arrow (the chevron already
    /// reads as "more"). `.fixedSize` keeps the glyph from stretching the half.
    private var chevronHalf: some View {
        Menu {
            moreMenuItems
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .padding(.leading, 9)
                .padding(.trailing, 12)
                .frame(height: Self.controlHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }

    /// The chevron's overflow items, mirroring their in-popover entry points. `autoenablesItems` has no
    /// SwiftUI equivalent, so the Check for Updates item disables itself when Sparkle can't currently
    /// check — e.g. dev builds with no feed, or while a check is already in flight. Customize carries its
    /// bare-⏎ key equivalent so the menu shows the shortcut: when the menu is open the item handles ⏎;
    /// when it's closed the `PopoverDismissReader` monitor handles (and consumes) ⏎ first, so the item's
    /// equivalent can't double-fire. Same split as the old Settings ⌘, item / the Quit ⌘Q item below.
    @ViewBuilder
    private var moreMenuItems: some View {
        Button { toggle(.customize) } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        }
        .keyboardShortcut(.return, modifiers: [])
        Button { updater.checkForUpdates() } label: {
            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!updater.canCheckForUpdates)

        Divider()

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
