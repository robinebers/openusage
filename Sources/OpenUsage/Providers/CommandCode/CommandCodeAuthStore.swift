import Foundation

struct CommandCodeAuth: Hashable, Sendable {
    var apiKey: String
}

enum CommandCodeAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case credentialsUnreadable
    case invalidCredentials
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run cmd login and try again."
        case .credentialsUnreadable:
            return "Couldn't read Command Code credentials. Check ~/.commandcode/auth.json permissions or sign in again."
        case .invalidCredentials:
            return "Command Code credentials are invalid. Run cmd login again."
        case .sessionExpired:
            return "Command Code session expired. Run cmd login again."
        }
    }
}

/// Reads the credential sources used by the Command Code CLI itself. The environment variable wins,
/// matching the CLI's `getAuthKey()` behavior; otherwise the persisted `apiKey` is read from
/// `~/.commandcode/auth.json`. Only the key is decoded, so account names and identifiers never cross
/// the provider boundary.
struct CommandCodeAuthStore: Sendable {
    static let credentialsPath = "~/.commandcode/auth.json"
    static let environmentName = "COMMAND_CODE_API_KEY"

    var files: TextFileAccessing
    var environment: EnvironmentReading

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        self.files = files
        self.environment = environment
    }

    func loadAuth() throws -> CommandCodeAuth? {
        if let key = trimmed(environment.value(for: Self.environmentName)) {
            return CommandCodeAuth(apiKey: key)
        }

        let text: String?
        do {
            text = try files.readTextIfPresent(Self.credentialsPath)
        } catch {
            throw CommandCodeAuthError.credentialsUnreadable
        }
        guard let text else { return nil }

        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(CredentialPayload.self, from: data),
              let key = trimmed(payload.apiKey)
        else {
            throw CommandCodeAuthError.invalidCredentials
        }
        return CommandCodeAuth(apiKey: key)
    }

    private func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct CredentialPayload: Decodable {
    var apiKey: String?
}
