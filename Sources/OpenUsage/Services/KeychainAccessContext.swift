import Foundation
import Synchronization

/// One credential operation's permission to present macOS authorization UI, plus what the Keychain
/// refused while it ran. Only explicit user actions (welcome-screen Connect, turning a provider on,
/// a manual refresh) create an interactive context; launch, detection, and scheduled refreshes stay
/// silent. Background work never borrows permission from another concurrent operation.
final class KeychainAccessContext: Sendable {
    @TaskLocal static var current: KeychainAccessContext?
    static var allowsInteraction: Bool { current?.allowsInteraction == true }

    let allowsInteraction: Bool
    private let refusal = Mutex<KeychainAccessError?>(nil)

    init(allowsInteraction: Bool) { self.allowsInteraction = allowsInteraction }

    /// Why a Keychain read or write failed during this operation, if one did. A denial outranks a
    /// busy refusal: it is the one the user has to act on.
    var refused: KeychainAccessError? { refusal.withLock { $0 } }

    func record(_ error: KeychainAccessError) {
        refusal.withLock { current in
            if current != .permissionNeeded { current = error }
        }
    }
}

enum KeychainAccessError: LocalizedError, CategorizedError, Equatable {
    /// macOS needs the user to approve access; only an explicit action may ask.
    case permissionNeeded
    /// A background request was refused while another request waited on the user.
    case busy

    var errorCategory: ErrorCategory { .credentialAccess }

    var errorDescription: String? {
        switch self {
        case .permissionNeeded:
            "Access to saved credentials is needed. Choose Refresh for this provider to allow access."
        case .busy:
            "Waiting for another Keychain request to finish. This provider will retry shortly."
        }
    }
}
