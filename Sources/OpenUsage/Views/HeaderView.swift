import AppKit
import SwiftUI

/// The dashboard footer's trailing control: a **split button** in Liquid Glass — one capsule with
/// "Customize" on the left and a chevron segment on the right, divided by a hairline (the Export ▾
/// idiom system apps use). Clicking "Customize" opens the Customize screen; clicking the chevron opens
/// the overflow menu (Settings / Share Screenshot / Check for Updates / About / Quit). Customize leads
/// because it's the screen users reach for most when shaping the dashboard; Settings stays one click
/// away in the overflow (and always via ⌘,).
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
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(UpdaterController.self) private var updater
    @Environment(\.colorScheme) private var colorScheme
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
                customizeHalf
                Divider()
                    .frame(height: 16)
                chevronHalf
            }
            .fixedSize()
            .interactiveGlass(in: Capsule())
        }
    }

    /// Left half: opens Customize. `.buttonStyle(.plain)` strips the system chrome so the shared glass
    /// is the only surface; `contentShape` makes the whole padded half clickable. ⏎ opens Customize
    /// from anywhere via `PopoverKeyReader`, so the shortcut isn't registered here (which would also
    /// flag the button as the window's default and draw a pulsing ring) — the tooltip surfaces it.
    private var customizeHalf: some View {
        Button { toggle(.customize) } label: {
            Text("Customize")
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 14)
                .padding(.trailing, 11)
                .frame(height: Self.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip("Customize (⏎)")
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
    /// check — e.g. dev builds with no feed, or while a check is already in flight. Settings carries its
    /// ⌘, key equivalent so the menu shows the shortcut: when the menu is open the item handles ⌘,;
    /// when it's closed the `PopoverDismissReader` monitor handles (and consumes) ⌘, first, so the item's
    /// equivalent can't double-fire. Same split as the Quit ⌘Q item below.
    @ViewBuilder
    private var moreMenuItems: some View {
        Button { toggle(.settings) } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        shareScreenshotMenu

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

    /// The footer's "Share Screenshot" submenu: one entry per provider currently showing on the
    /// dashboard (`displayGroups` — enabled providers with at least one visible metric), so a screenshot
    /// is reachable without right-clicking a card. Each entry runs the same render path as the per-provider
    /// right-click "Share Screenshot": a branded PNG of that provider's card copied to the clipboard. The
    /// menu renders in its own `NSMenu`-backed window, so firing an item doesn't close the popover the way
    /// a navigation toggle would — the share card reads the same live stores the dashboard does.
    @ViewBuilder
    private var shareScreenshotMenu: some View {
        let groups = layout.displayGroups
        Menu {
            if groups.isEmpty {
                // No provider is showing anything to screenshot — grey the item out instead of offering
                // an empty submenu.
                Button("No Enabled Providers") {}
                    .disabled(true)
            } else {
                ForEach(groups) { group in
                    Button(group.provider.displayName) { shareCard(group) }
                }
            }
        } label: {
            Label("Share Screenshot", systemImage: "square.and.arrow.up")
        }
    }

    /// Renders the provider's branded share card and copies the PNG to the clipboard — the same action as
    /// the dashboard's per-provider right-click "Share Screenshot". The appearance comes from the
    /// popover's own `colorScheme`: the footer lives in the popover panel, whose appearance is
    /// `AppearanceSetting.current` (explicit for Light/Dark, the menu bar for System), so the export
    /// matches the card on screen instead of guessing from `NSApp.effectiveAppearance`.
    private func shareCard(_ group: ProviderGroup) {
        ShareCardRenderer.share(
            group: group,
            dataStore: dataStore,
            layout: layout,
            appearance: colorScheme
        )
    }

    private func toggle(_ screen: PopoverScreen) {
        withAnimation(Motion.modeSwitch) {
            layout.screen = layout.screen == screen ? .dashboard : screen
        }
    }
}
