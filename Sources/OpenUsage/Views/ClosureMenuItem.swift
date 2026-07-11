import AppKit

/// An `NSMenuItem` that runs a closure when selected, so menus can be built inline without a separate
/// target/action object. `keyEquivalent` defaults to none; when set it uses the ⌘ modifier (the
/// standard for menu shortcuts like ⌘Q).
///
/// Used by the status-item right-click menu (`StatusItemController`), which is a real `NSMenu`. The
/// footer's "Options" menu is a SwiftUI `Menu` and does not need this.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, systemSymbol: String? = nil, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
        if let systemSymbol {
            image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}
