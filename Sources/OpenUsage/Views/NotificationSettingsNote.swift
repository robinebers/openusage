import AppKit
import SwiftUI

struct NotificationSettingsNote: View {
    var bundleIdentifier: String = Bundle.main.bundleIdentifier!
    var openSettings: (URL) async throws -> Void = { url in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
    }
    var dismissPopover: (() -> Void)?
    @State private var isOpening = false
    @State private var openingFailed = false

    var body: some View {
        Button(action: open) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.notice)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("System Settings")
        .disabled(isOpening)
        .alert("Couldn't Open System Settings", isPresented: $openingFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Open System Settings, choose Notifications, then OpenUsage.")
        }
    }

    private var message: AttributedString {
        var text = AttributedString("Notifications are off for OpenUsage in ")
        var link = AttributedString("System Settings")
        link.foregroundColor = .accentColor
        text += link
        text += AttributedString(".")
        return text
    }

    private func open() {
        guard !isOpening else { return }
        isOpening = true
        // Capture the initiating panel before System Settings takes focus. Its normal dismissal
        // path also clears the menu-bar highlight and stops the outside-click monitor.
        let dismiss = dismissPopover
            ?? (NSApp.currentEvent?.window as? MenuBarPanel)?.onDismiss
            ?? (NSApp.keyWindow as? MenuBarPanel)?.onDismiss
        Task {
            defer { isOpening = false }
            do {
                try await openSettings(settingsURL)
                dismiss?()
            } catch {
                AppLog.error(.notifications, "could not open notification settings: \(error.localizedDescription)")
                openingFailed = true
            }
        }
    }

    private var settingsURL: URL {
        var components = URLComponents(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        components.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)]
        return components.url!
    }
}
