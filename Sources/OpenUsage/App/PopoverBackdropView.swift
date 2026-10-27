import AppKit

/// The popover panel's backdrop: a solid `NSBox` in `Theme.trayNSColor`, the tray the content sits on,
/// pinned to the full frame so the data region never reveals the desktop, a height morph never shows a
/// transparent strip, and any region SwiftUI leaves unpainted shows the tray, not a raw hole.
final class PopoverBackdropView: NSBox {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        boxType = .custom
        titlePosition = .noTitle
        borderWidth = 0
        contentViewMargins = .zero
        fillColor = Theme.trayNSColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
