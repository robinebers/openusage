import Foundation
#if os(Windows)
import Win32Shim
#endif

enum KeychainError: Error, LocalizedError, Equatable {
    case writeFailed(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message):
            return message.isEmpty ? "Credential vault write failed." : message
        case .readFailed(let message):
            return message.isEmpty ? "Credential vault read failed." : message
        }
    }
}

#if os(Windows)

/// Reads generic passwords from Windows Credential Manager via `CredReadW`.
///
/// go-keyring / `cmdkey` TargetName convention (verified on this machine):
/// - `service:account` — e.g. `gemini:antigravity`, `gh:github.com:Cagatay342`
/// - Service-only entries use the service string as TargetName — e.g. `gh:github.com:`
struct WindowsCredentialVaultAccessor: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? {
        try readCredential(targetNames: [service])
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try readGenericPassword(service: service)
    }

    func readGenericPassword(service: String, account: String) throws -> String? {
        try readCredential(targetNames: [
            "\(service):\(account)",
            "\(service)/\(account)",
            service
        ])
    }

    func writeGenericPassword(service: String, value: String) throws {
        throw KeychainError.writeFailed("read-only: Credential Manager writes are disabled in Phase 2")
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try writeGenericPassword(service: service, value: value)
    }

    private func readCredential(targetNames: [String]) throws -> String? {
        for target in targetNames {
            if let value = try readCredential(targetName: target) {
                return value
            }
        }
        return nil
    }

    private func readCredential(targetName: String) throws -> String? {
        let wide = Array(targetName.utf16) + [0]
        return try wide.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            var out: UnsafeMutablePointer<CChar>?
            var outLen: Int = 0
            let found = ou_cred_read_generic_utf8(base, &out, &outLen)
            defer {
                if let out { ou_cred_free_string(out) }
            }
            guard found != 0, let out else { return nil }
            let value = String(cString: out).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}

#else

struct WindowsCredentialVaultAccessor: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? { nil }
    func writeGenericPassword(service: String, value: String) throws {}
    func readGenericPasswordForCurrentUser(service: String) throws -> String? { nil }
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {}
    func readGenericPassword(service: String, account: String) throws -> String? { nil }
}

#endif
