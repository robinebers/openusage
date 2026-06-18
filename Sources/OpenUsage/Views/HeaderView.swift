import AppKit
import SwiftUI

/// Footer "More" menu + Settings round glass buttons. The Settings button is unchanged: it toggles
/// the in-popover Settings screen and its active state becomes a prominent checkmark "Done". The
/// leading control is the same round glass button that pops a "More" pull-down (Customize Metrics /
/// About / Quit); while the Customize screen is open it morphs into the prominent "Done" button that
/// returns to the dashboard, so Customize keeps a visible exit (Esc also backs out).
struct HeaderView: View {
    @Environment(LayoutStore.self) private var layout
    /// Anchors the "More" pull-down under its button. `@State` keeps one stable instance.
    @State private var moreMenuAnchor = PopUpMenuAnchor()

    var body: some View {
        // Group the adjacent glass buttons so the system samples them coherently (glass cannot sample
        // other glass). The gap stays wider than the container's merge distance, so they read as two
        // distinct circles rather than blending into one pill.
        HStack(spacing: 12) {
            leadingControl

            roundButton(
                layout.screen == .settings ? "Done" : "Settings",
                systemImage: layout.screen == .settings ? "checkmark" : "gearshape",
                prominent: layout.screen == .settings
            ) {
                toggle(.settings)
            }
            // The system-wide Settings key equivalent, scoped to the popover being key.
            .keyboardShortcut(",", modifiers: .command)
        }
        .glassButtonGroup(spacing: 4)
    }

    /// While the Customize screen is open the slot is the prominent "Done" button — clicking it (or ⏎)
    /// returns to the dashboard, matching how the old Customize button behaved. Otherwise it's the
    /// "More" button: the same round glass control, opening a pull-down whose "Customize Metrics" item
    /// is the way into Customize.
    @ViewBuilder
    private var leadingControl: some View {
        if layout.screen == .customize {
            roundButton("Done", systemImage: "checkmark", prominent: true) {
                toggle(.customize)
            }
            // Plain Return (not .defaultAction, which would restyle the glass button as default).
            .keyboardShortcut(.return, modifiers: [])
        } else {
            roundButton("More", systemImage: "ellipsis", prominent: false) {
                presentMoreMenu()
            }
            // The anchor view fills the button's frame so the menu drops from directly under it.
            .background(PopUpMenuAnchorView(anchor: moreMenuAnchor))
            // ⏎ still jumps straight into Customize, as it did before the standalone Customize
            // button became this "More" menu. A key-only button restores that affordance without
            // hijacking the visible control's menu action.
            .background(enterCustomizeReturnKey)
        }
    }

    /// A zero-size, key-only button mapping plain ⏎ to entering Customize. Mounted only on the
    /// non-Customize screens — the Customize "Done" button binds ⏎ there — so Return enters
    /// Customize from the dashboard (or Settings) and exits it from Customize, the way the
    /// standalone Customize button behaved before it folded into the More menu. The popover has no
    /// text fields, so a plain-Return key equivalent can't steal Return from an editing control.
    private var enterCustomizeReturnKey: some View {
        Button { toggle(.customize) } label: { Color.clear.frame(width: 0, height: 0) }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityHidden(true)
    }

    /// Builds and pops the "More" pull-down as a native `NSMenu`, so the trigger stays the exact glass
    /// `roundButton` (a SwiftUI `Menu` styled as a button does not match it). Quit carries the standard
    /// ⌘Q equivalent.
    private func presentMoreMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Customize Metrics", systemSymbol: "slider.horizontal.3") {
            toggle(.customize)
        })
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
    /// keeps both circles the same diameter regardless of glyph width.
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
            // The popover's only two buttons: a larger control costs nothing and gives a bigger target.
            .controlSize(.large)
            .help(title)
    }
}
