import Foundation

/// Typed failures for the local Zcode scanner, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum ZcodeUsageError: Error, LocalizedError, Equatable {
    /// Zcode databases exist but none could be read this refresh. Failing loudly here beats rendering
    /// authoritative-looking $0 tiles from an empty scan.
    case databaseUnreadable

    var errorDescription: String? {
        switch self {
        case .databaseUnreadable:
            return "Couldn't read Zcode's local database. Quit Zcode and refresh, or check ~/.zcode's permissions."
        }
    }
}
