import Foundation

/// Where OpenUsage keeps its always-available glance surface.
///
/// Menu Bar preserves the established status-item experience. Side Notch replaces that item with a
/// screen-edge handle that opens the same starred metrics in a compact vertical strip. The choice is
/// intentionally independent of the metric layout: switching surfaces never changes what is starred.
enum AppSurfaceModeSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case menuBar
    case sideNotch

    static let key = "openusage.surfaceMode"
    static var fallback: AppSurfaceModeSetting { .menuBar }

    /// Posted by the Settings picker and Reset All Settings so the AppKit window owner can swap the
    /// live surface immediately. `UserDefaults.didChangeNotification` is intentionally not the bridge:
    /// it does not identify the changed key and is not guaranteed to arrive synchronously.
    static let didChangeNotification = Notification.Name("AppSurfaceModeSettingDidChange")

    var label: String {
        switch self {
        case .menuBar: return "Menu Bar"
        case .sideNotch: return "Side Notch"
        }
    }

    @MainActor
    static func notifyDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
