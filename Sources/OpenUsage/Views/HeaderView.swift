import AppKit
import SwiftUI

/// The footer's lone glass control: a "More" pull-down button (Customize / Settings / Check for Updates /
/// About / Quit). On the dashboard it shows; the Customize and Settings screens carry their own
/// top-leading back button (`DashboardView.navBar`) to return home — the macOS-native place for it — so
/// the footer control simply drops away there rather than morphing into a trailing "Done".
///
/// It's a SwiftUI `Menu` with `.menuStyle(.button)`: the native drop-down-button pattern, which draws the
/// glass button plus a disclosure chevron and presents the menu itself. The menu renders in its own
/// `NSMenu`-backed window, which `StatusItemController.shouldKeepPanelOpen` already keeps the popover open
/// for (same rule that covers the Settings pickers' popups). A hidden ⌘, button preserves the system
/// Settings shortcut from anywhere in the popover, since a menu's own key equivalents only fire while it's open.
struct HeaderView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(UpdaterController.self) private var updater
    /// The screen this footer belongs to. Footers are per-page now (they slide with their page), so the
    /// "More" button keys off the page it's drawn in — not the global current screen, which flips at the
    /// start of a slide and would otherwise pop the button off the outgoing page mid-transition.
    let screen: PopoverScreen

    var body: some View {
        leadingControl
            .glassButtonGroup(spacing: 4)
            // Carries the ⌘, Settings shortcut now that there's no dedicated gear button (see below).
            .background(settingsShortcut)
    }

    /// On the dashboard this is the "More" pull-down. `.menuStyle(.button)` presents it as a button control
    /// with a disclosure chevron — the standard macOS drop-down button — while `.glassButtonStyle()` keeps it
    /// on the footer's Liquid Glass (bordered on macOS 15).
    @ViewBuilder
    private var leadingControl: some View {
        if screen == .dashboard {
            Menu {
                moreMenuItems
            } label: {
                // Icon-only "More" affordance; `.menuStyle(.button)` adds the drop-down chevron beside it.
                // The `Label` title still carries the accessible name for VoiceOver.
                Label("More", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .glassButtonStyle()
            .buttonBorderShape(.capsule)
            // The footer's only control: a larger size costs nothing and gives a bigger target.
            .controlSize(.large)
        }
    }

    /// The "More" menu items, mirroring their in-popover entry points. `autoenablesItems` has no SwiftUI
    /// equivalent, so the Check for Updates item disables itself when Sparkle can't currently check — e.g.
    /// dev builds with no feed, or while a check is already in flight. Settings (⌘,) and Customize (⏎) are
    /// reachable by their global shortcuts (the hidden button below and `PopoverKeyReader`), so they don't
    /// repeat a key equivalent here that would double-register.
    @ViewBuilder
    private var moreMenuItems: some View {
        Button { toggle(.settings) } label: {
            Label("Settings", systemImage: "gearshape")
        }
        Button { toggle(.customize) } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
        }
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

    /// Keeps the system ⌘, Settings shortcut working from anywhere in the popover. The menu's Settings
    /// item can't carry it (a menu key equivalent only fires while that menu is open), so this hidden,
    /// zero-size button carries the shortcut the rest of the time. It never draws.
    private var settingsShortcut: some View {
        Button("") { toggle(.settings) }
            .keyboardShortcut(",", modifiers: .command)
            .frame(width: 0, height: 0)
            .hidden()
            .accessibilityHidden(true)
    }

    private func toggle(_ screen: PopoverScreen) {
        withAnimation(Motion.modeSwitch) {
            layout.screen = layout.screen == screen ? .dashboard : screen
        }
    }
}
