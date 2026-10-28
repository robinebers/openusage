import AppKit

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
