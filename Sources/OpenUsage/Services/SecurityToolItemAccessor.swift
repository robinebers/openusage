import Foundation
import Security

/// Keychain access through `/usr/bin/security`, for logins whose own tools save them that way.
///
/// Saving new data resets which apps may read an item without asking: only the app that saved it
/// keeps access. Claude Code, gh, Cursor's agent, and Antigravity save through `security`, so
/// OpenUsage reads and saves those logins through it too. The user's Always Allow then survives
/// every renewal, and OpenUsage's saves never lock those tools out of their own logins.
struct SecurityToolItemAccessor: SecurityItemAccessing {
    var processRunner: any ProcessRunning = SystemProcessRunner()

    /// Ending `security` closes the popup it may be showing before the user can choose Always Allow,
    /// so this only guards against a hung process.
    static let popupWait: TimeInterval = 10 * 60

    static func handles(service: String) -> Bool {
        service.hasPrefix(ClaudeAuthStore.keychainServicePrefix)
            || service.hasSuffix(KeychainICloudDeviceIDStore.serviceSuffix)
            || [
                CopilotAuthStore.ghKeychainService,
                CursorAuthStore.keychainAccessTokenService,
                CursorAuthStore.keychainRefreshTokenService,
                AntigravityAuthStore.keychainService,
            ].contains(service)
    }

    func readGenericPasswordData(service: String, account: String?) -> (status: OSStatus, data: Data?) {
        let result = run(["find-generic-password"] + accountArguments(account) + ["-s", service, "-w"], service: service)
        return (result.status, result.status == errSecSuccess ? Data(result.output.utf8) : nil)
    }

    /// Reads attributes only, which never shows a popup.
    func firstGenericPasswordAccount(service: String) -> (status: OSStatus, account: String?) {
        SystemSecurityItemAccessor().firstGenericPasswordAccount(service: service)
    }

    /// `-U` updates the matching item in place, or adds it when none exists. `security` refuses to
    /// save without `-a`, so a login without an account is saved under an empty one.
    func updateGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        let value = String(decoding: data, as: UTF8.self)
        return run(["add-generic-password", "-U", "-a", account ?? "", "-s", service, "-w", value], service: service).status
    }

    func addGenericPasswordData(service: String, account: String?, data: Data) -> OSStatus {
        updateGenericPasswordData(service: service, account: account, data: data)
    }

    private func accountArguments(_ account: String?) -> [String] {
        account.map { ["-a", $0] } ?? []
    }

    private func run(_ arguments: [String], service: String) -> (status: OSStatus, output: String) {
        let result: ProcessResult
        do {
            result = try processRunner.run(
                executable: "/usr/bin/security",
                arguments: arguments,
                environment: [:],
                timeout: Self.popupWait
            )
        } catch {
            AppLog.error(.keychain, "security failed for '\(service)': \(error.localizedDescription)")
            return (errSecInternalComponent, "")
        }
        if result.succeeded { return (errSecSuccess, result.stdout) }
        if let status = Self.statusByExitCode[result.exitCode] { return (status, "") }
        AppLog.warn(.keychain, "security exited \(result.exitCode) for '\(service)': \(result.stderr)")
        return (errSecInternalComponent, "")
    }

    /// `security` exits with the low byte of the failing status.
    private static let statusByExitCode = Dictionary(uniqueKeysWithValues: [
        errSecItemNotFound, errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed,
    ].map { ($0 & 0xFF, $0) })
}
