import Foundation

struct FactoryAuth: Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
}

enum FactoryAuthSource: Hashable, Sendable {
    case v2File(authPath: String, keyPath: String, keyMaterial: String)
    case legacyFile(path: String)
    case keychain(service: String)
}

struct FactoryAuthState: Hashable, Sendable {
    var auth: FactoryAuth
    var source: FactoryAuthSource
}

enum FactoryAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case invalidCredentialData
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `droid` to authenticate."
        case .invalidCredentialData:
            return "Invalid Droid auth file. Run `droid` to authenticate."
        case .sessionExpired:
            return "Droid session expired. Run `droid` to log in again."
        }
    }
}

struct FactoryAuthStore: Sendable {
    static let authV2Path = "~/.factory/auth.v2.file"
    static let authV2KeyPath = "~/.factory/auth.v2.key"
    static let legacyAuthPaths = ["~/.factory/auth.encrypted", "~/.factory/auth.json"]
    static let keychainServices = ["Factory Token", "Factory token", "Factory Auth", "Droid Auth"]
    static let refreshBuffer: TimeInterval = 24 * 60 * 60

    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.keychain = keychain
        self.now = now
    }

    func loadAuthState() -> FactoryAuthState? {
        if let state = loadV2Auth() { return state }
        for path in Self.legacyAuthPaths {
            if let state = loadLegacyAuth(at: path) { return state }
        }
        return loadKeychainAuth()
    }

    func hasAnyCredentialSource() -> Bool {
        if files.exists(Self.authV2Path), files.exists(Self.authV2KeyPath) { return true }
        if Self.legacyAuthPaths.contains(where: files.exists) { return true }
        for service in Self.keychainServices {
            if (try? keychain.readGenericPassword(service: service))?.isEmpty == false {
                return true
            }
        }
        return false
    }

    func needsRefresh(accessToken: String) -> Bool {
        guard let expiry = tokenExpiry(accessToken) else { return false }
        return expiry.timeIntervalSince(now()) <= Self.refreshBuffer
    }

    func tokenExpiry(_ accessToken: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(accessToken)?["exp"].flatMap(ProviderParse.number) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    func accessTokenIsUsable(_ accessToken: String) -> Bool {
        guard let expiry = tokenExpiry(accessToken) else { return true }
        return expiry > now()
    }

    func userID(from accessToken: String) -> String? {
        guard let payload = ProviderParse.jwtPayload(accessToken) else { return nil }
        for key in ["sub", "user_id", "userId"] {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    func save(_ state: FactoryAuthState) throws {
        let payload = try JSONSerialization.data(
            withJSONObject: authJSONObject(state.auth),
            options: [.prettyPrinted, .sortedKeys]
        )
        let text = String(decoding: payload, as: UTF8.self)

        switch state.source {
        case .v2File(let authPath, _, let keyMaterial):
            let envelope = try FactoryAuthCrypto.encrypt(plaintext: text, keyBase64: keyMaterial)
            try files.writeText(authPath, envelope)
        case .legacyFile(let path):
            try files.writeText(path, text)
        case .keychain(let service):
            try keychain.writeGenericPassword(service: service, value: text)
        }
    }

    static func parseAuthPayload(_ text: String, allowPartial: Bool = false) -> FactoryAuth? {
        if let object = jsonObject(from: text) {
            return normalizedAuth(from: object, allowPartial: allowPartial)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeJWT(trimmed) {
            return FactoryAuth(accessToken: trimmed, refreshToken: nil)
        }
        return nil
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        if let object = ProviderParse.jsonObject(Data(text.utf8)) {
            return object
        }
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
        return ProviderParse.jsonObject(Data(decoded.utf8))
    }

    private func loadV2Auth() -> FactoryAuthState? {
        guard files.exists(Self.authV2Path), files.exists(Self.authV2KeyPath) else { return nil }
        do {
            let envelope = try files.readText(Self.authV2Path)
            let keyMaterial = try files.readText(Self.authV2KeyPath)
            let decrypted = try FactoryAuthCrypto.decrypt(envelope: envelope, keyBase64: keyMaterial)
            guard let auth = Self.parseAuthPayload(decrypted, allowPartial: true) else { return nil }
            return FactoryAuthState(
                auth: auth,
                source: .v2File(authPath: Self.authV2Path, keyPath: Self.authV2KeyPath, keyMaterial: keyMaterial.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        } catch {
            AppLog.warn(LogTag.auth("factory"), "failed to read encrypted Droid auth: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadLegacyAuth(at path: String) -> FactoryAuthState? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let auth = Self.parseAuthPayload(text, allowPartial: true)
        else {
            return nil
        }
        return FactoryAuthState(auth: auth, source: .legacyFile(path: path))
    }

    private func loadKeychainAuth() -> FactoryAuthState? {
        for service in Self.keychainServices {
            guard let value = try? keychain.readGenericPassword(service: service),
                  let auth = Self.parseAuthPayload(value)
            else {
                continue
            }
            return FactoryAuthState(auth: auth, source: .keychain(service: service))
        }
        return nil
    }

    private static func normalizedAuth(from object: [String: Any], allowPartial: Bool) -> FactoryAuth? {
        let tokens = object["tokens"] as? [String: Any]
        let access = stringValue(object, keys: ["access_token", "accessToken"])
            ?? stringValue(tokens ?? [:], keys: ["access_token", "accessToken"])
        let refresh = stringValue(object, keys: ["refresh_token", "refreshToken"])
            ?? stringValue(tokens ?? [:], keys: ["refresh_token", "refreshToken"])
        if access != nil || (allowPartial && refresh != nil) {
            return FactoryAuth(accessToken: access, refreshToken: refresh)
        }
        return nil
    }

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return value
            }
        }
        return nil
    }

    private static func authJSONObject(_ auth: FactoryAuth) -> [String: String] {
        var object: [String: String] = [:]
        if let accessToken = auth.accessToken { object["access_token"] = accessToken }
        if let refreshToken = auth.refreshToken { object["refresh_token"] = refreshToken }
        return object
    }

    private static func looksLikeJWT(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty }
    }
}
