import Foundation

struct DevinAuth: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case credentialsFile
        case appState
    }

    var apiKey: String
    var apiServerUrl: String?
    var source: Source
}

enum DevinAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Run devin auth login or sign in to Devin and try again."
        }
    }
}

struct DevinAuthStore: Sendable {
    static let credentialsPath = "~/.local/share/devin/credentials.toml"
    static let stateDBPath = "~/Library/Application Support/Devin/User/globalStorage/state.vscdb"
    static let defaultAPIServerURL = "https://server.codeium.com"

    var files: TextFileAccessing
    var sqlite: SQLiteAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        sqlite: SQLiteAccessing = SQLiteCLIAccessor()
    ) {
        self.files = files
        self.sqlite = sqlite
    }

    func loadCredentialsFile() -> DevinAuth? {
        guard files.exists(Self.credentialsPath),
              let text = try? files.readText(Self.credentialsPath),
              let apiKey = Self.readTomlString(text, key: "windsurf_api_key")
        else {
            return nil
        }

        return DevinAuth(
            apiKey: apiKey,
            apiServerUrl: Self.cleanAPIServerURL(Self.readTomlString(text, key: "api_server_url")),
            source: .credentialsFile
        )
    }

    func loadAppAuth() -> DevinAuth? {
        let sql = "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1"
        guard let value = try? sqlite.queryValue(path: Self.stateDBPath, sql: sql),
              let valueData = value.data(using: .utf8),
              let auth = (try? JSONSerialization.jsonObject(with: valueData)) as? [String: Any],
              let apiKey = (auth["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            return nil
        }

        return DevinAuth(apiKey: apiKey, apiServerUrl: nil, source: .appState)
    }

    func effectiveAPIServerURL(_ auth: DevinAuth) -> String {
        auth.apiServerUrl ?? Self.defaultAPIServerURL
    }

    static func cleanAPIServerURL(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasPrefix("https://")
        else {
            return nil
        }
        let withoutTrailingSlashes = trimmed.trimmingTrailingSlashes
        return withoutTrailingSlashes.isEmpty ? nil : withoutTrailingSlashes
    }

    static func readTomlString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key
            else {
                continue
            }

            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }

            if value.first == "\"" || value.first == "'" {
                return readQuotedTomlString(value)
            }

            if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private static func readQuotedTomlString(_ value: String) -> String? {
        guard let quote = value.first else { return nil }
        var output = ""
        var previous: Character?
        for character in value.dropFirst() {
            if character == quote, previous != "\\" {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            output.append(character)
            previous = character
        }
        return nil
    }
}
