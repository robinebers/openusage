import Foundation

enum OpenCodeGoUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case noUsageSource

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't read OpenCode Go usage data. Check your local endpoint source."
        case .invalidResponse:
            return "OpenCode Go usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "OpenCode Go request failed (HTTP \(status))."
        case .noUsageSource:
            return "No OpenCode Go usage data source found."
        }
    }
}

