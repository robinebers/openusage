import Foundation

/// One credential operation's permission to present macOS authorization UI. Background work and
/// discovery never borrow permission from another concurrent operation.
final class KeychainAccessContext: @unchecked Sendable {
    enum Mode: Sendable { case discovery, background, interactive }
    @TaskLocal static var current: KeychainAccessContext?
    let mode: Mode
    private let lock = NSLock()
    private var requiresPermission = false

    init(mode: Mode) { self.mode = mode }
    static var allowsInteraction: Bool { current?.mode == .interactive }
    var needsPermission: Bool { lock.withLock { requiresPermission } }
    func recordPermissionNeeded() { lock.withLock { requiresPermission = true } }
}

struct KeychainPermissionNeeded: LocalizedError, CategorizedError {
    var errorCategory: ErrorCategory { .credentialAccess }
    var errorDescription: String? {
        "Access to saved credentials is needed. Choose Refresh for this provider to allow access."
    }
}
