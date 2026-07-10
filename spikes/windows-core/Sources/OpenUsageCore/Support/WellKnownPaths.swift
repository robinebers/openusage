import Foundation

/// Cross-platform well-known directory helpers for the Windows core spike.
enum WellKnownPaths {
    /// User home directory (`%USERPROFILE%` on Windows, `~` on macOS).
    static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Roaming app data (`%APPDATA%` on Windows, `~/Library/Application Support` on macOS).
    static var applicationSupport: URL {
        #if os(Windows)
        if let appData = ProcessInfo.processInfo.environment["APPDATA"], !appData.isEmpty {
            return URL(fileURLWithPath: appData, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Local app data (`%LOCALAPPDATA%` on Windows, `~/Library` on macOS).
    static var localAppData: URL {
        #if os(Windows)
        if let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !localAppData.isEmpty {
            return URL(fileURLWithPath: localAppData, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    /// Cursor VS Code state DB (`state.vscdb`) under globalStorage.
    static var cursorStateDBPath: String {
        #if os(Windows)
        applicationSupport
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb", isDirectory: false)
            .path
        #else
        "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        #endif
    }

    /// Expand `~` and `~/…` to the current user's home directory.
    static func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        if path == "~" { return home }
        return home + String(path.dropFirst())
    }
}
