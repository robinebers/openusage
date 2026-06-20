import AppKit
import SwiftUI

/// The footer's lone round glass control plus the "More" pull-down behind it. On the dashboard the
/// button pops the pull-down (Customize / Settings / Check for Updates / About / Quit); on the Customize
/// or Settings screen it morphs into the prominent checkmark "Done" that returns to the dashboard, so
/// each screen keeps a visible exit (Esc/⏎ also back out). Settings folded from its own gear button into
/// the menu, so a hidden ⌘, button preserves that system shortcut from anywhere in the popover.
struct HeaderView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(UpdaterController.self) private var updater
    /// Anchors the "More" pull-down under its button. `@State` keeps one stable instance.
    @State private var moreMenuAnchor = PopUpMenuAnchor()

    var body: some View {
        leadingControl
            .glassButtonGroup(spacing: 4)
            // Carries the ⌘, Settings shortcut now that there's no dedicated gear button (see below).
            .background(settingsShortcut)
    }

    /// On the dashboard this is the "More" button, opening the pull-down whose "Customize" and "Settings"
    /// items are the ways into those screens. On any other screen it morphs into the prominent "Done"
    /// button that returns to the dashboard (clicking it, or pressing ⏎/Esc, which `PopoverKeyReader`
    /// routes for the whole popover).
    @ViewBuilder
    private var leadingControl: some View {
        if layout.screen == .dashboard {
            roundButton("More", systemImage: "ellipsis", prominent: false) {
                presentMoreMenu()
            }
            // The anchor view fills the button's frame so the menu drops from directly under it.
            .background(PopUpMenuAnchorView(anchor: moreMenuAnchor))
        } else {
            roundButton("Done", systemImage: "checkmark", prominent: true) {
                withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
            }
        }
    }

    /// Keeps the system ⌘, Settings shortcut working from anywhere in the popover. The menu's Settings
    /// item shows ⌘, too, but a menu key equivalent only fires while that menu is open — this hidden,
    /// zero-size button carries the shortcut the rest of the time. It never draws.
    private var settingsShortcut: some View {
        Button("") { toggle(.settings) }
            .keyboardShortcut(",", modifiers: .command)
            .frame(width: 0, height: 0)
            .hidden()
            .accessibilityHidden(true)
    }

    /// Builds and pops the "More" pull-down as a native `NSMenu`, so the trigger stays the exact glass
    /// `roundButton` (a SwiftUI `Menu` styled as a button does not match it). Items mirror their
    /// in-popover shortcuts: Settings ⌘,, Customize ⏎, Quit ⌘Q. `autoenablesItems = false` lets the
    /// Check for Updates item stay greyed when Sparkle can't currently check — e.g. dev builds with no
    /// feed, or while a check is already in flight.
    private func presentMoreMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(ClosureMenuItem(title: "Settings", systemSymbol: "gearshape", keyEquivalent: ",") {
            toggle(.settings)
        })

        let customize = ClosureMenuItem(title: "Customize", systemSymbol: "slider.horizontal.3", keyEquivalent: "\r") {
            toggle(.customize)
        }
        // The bare Return that `PopoverKeyReader` already routes to Customize. Clearing the mask keeps it
        // showing as ⏎ rather than the ⌘⏎ that NSMenuItem renders by default.
        customize.keyEquivalentModifierMask = []
        menu.addItem(customize)

        let checkForUpdates = ClosureMenuItem(title: "Check for Updates…", systemSymbol: "arrow.triangle.2.circlepath") {
            updater.checkForUpdates()
        }
        checkForUpdates.isEnabled = updater.canCheckForUpdates
        menu.addItem(checkForUpdates)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "About OpenUsage", systemSymbol: "info.circle") {
            AboutPanel.present()
        })
        menu.addItem(ClosureMenuItem(title: "Quit OpenUsage", systemSymbol: "power", keyEquivalent: "q") {
            NSApplication.shared.terminate(nil)
        })
        moreMenuAnchor.present(menu)
    }

    private func toggle(_ screen: PopoverScreen) {
        withAnimation(Motion.modeSwitch) {
            layout.screen = layout.screen == screen ? .dashboard : screen
        }
    }

    /// A system Liquid Glass icon button (Tahoe) at the large control size — no custom icon
    /// font or shrunken control. On macOS 15 it falls back to a bordered button (no glass).
    /// `buttonBorderShape(.circle)` keeps the circular shape while preserving
    /// the glass highlight/shadow that `clipShape` would crop. Prominent = accent-filled glass for an
    /// active toggle state. The icon-only `Label` keeps the title for accessibility; the equal frame
    /// keeps the circle a consistent diameter regardless of glyph width.
    private func roundButton(
        _ title: String,
        systemImage: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let label = Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .frame(width: 16, height: 16)

        return Button(action: action) { label }
            .glassButtonStyle(prominent: prominent)
            .buttonBorderShape(.circle)
            // The footer's only button: a larger control costs nothing and gives a bigger target.
            .controlSize(.large)
            .hoverTooltip(title)
    }
}
