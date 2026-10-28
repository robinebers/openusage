import CryptoKit
import Foundation

enum ProviderAuthMethod: Sendable, Equatable {
    case oauth
    /// Signs in with a pasted API key, created on the provider's `keyPage`.
    case apiKey(keyPage: URL)
}

enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case antigravity
    case copilot
    case grok
    case ollama
    case opencodeGo = "opencode"
    case openrouter
    case zai

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .copilot: "Copilot"
        case .grok: "Grok"
        case .ollama: "Ollama"
        case .opencodeGo: "OpenCode"
        case .openrouter: "OpenRouter"
        case .zai: "Z.ai"
        }
    }

    /// The provider's quick links, in its card's right-click menu on the dashboard. The same links
    /// OpenUsage ships.
    var links: [ProviderLink] {
        switch self {
        case .claude: [.init(label: "Status Page", url: URL(string: "https://status.claude.com/")!),
                       .init(label: "Usage Dashboard", url: URL(string: "https://claude.ai/settings/usage")!)]
        case .codex: [.init(label: "Status Page", url: URL(string: "https://status.openai.com/")!),
                      .init(label: "Usage Dashboard", url: URL(string: "https://chatgpt.com/settings/usage")!)]
        case .cursor: [.init(label: "Status Page", url: URL(string: "https://status.cursor.com/")!),
                       .init(label: "Usage Dashboard", url: URL(string: "https://www.cursor.com/dashboard")!)]
        case .antigravity: []
        case .copilot: [.init(label: "Status Page", url: URL(string: "https://www.githubstatus.com/")!),
                        .init(label: "Usage Dashboard", url: URL(string: "https://github.com/settings/billing")!)]
        case .grok: [.init(label: "Usage Dashboard", url: URL(string: "https://grok.com/?_s=usage")!)]
        case .ollama: [.init(label: "Usage Dashboard", url: URL(string: "https://ollama.com/settings")!)]
        case .opencodeGo: [.init(label: "Status Page", url: URL(string: "https://status.opencode.ai/")!),
                           .init(label: "Usage Dashboard", url: URL(string: "https://opencode.ai/console")!)]
        case .openrouter: [.init(label: "Status Page", url: URL(string: "https://status.openrouter.ai/")!),
                           .init(label: "Usage Dashboard", url: URL(string: "https://openrouter.ai/activity")!)]
        case .zai: [.init(label: "Usage Dashboard", url: URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")!)]
        }
    }

    var authMethod: ProviderAuthMethod {
        switch self {
        case .claude, .codex, .cursor, .antigravity, .copilot, .grok: .oauth
        case .ollama: .apiKey(keyPage: URL(string: "https://ollama.com/settings/keys")!)
        case .opencodeGo: .apiKey(keyPage: URL(string: "https://opencode.ai/console")!)
        case .openrouter: .apiKey(keyPage: URL(string: "https://openrouter.ai/settings/management-keys")!)
        case .zai: .apiKey(keyPage: URL(string: "https://z.ai/manage-apikey/apikey-list")!)
        }
    }
}

struct Account: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: ProviderKind
    var label: String
    let addedAt: Date

    var cardID: String {
        "\(kind.rawValue)@\(id.uuidString.lowercased().prefix(8))"
    }

    init(id: UUID = UUID(), kind: ProviderKind, label: String, addedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.label = label
        self.addedAt = addedAt
    }
}

struct OAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var extras: [String: String]

    init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, extras: [String: String] = [:]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.extras = extras
    }

    /// The `extras` key for the provider account a sign-in belongs to (see `AccountCredential.identity`).
    static let identityKey = "account_identity"

    /// How long before `expiresAt` a token is refreshed: Claude Code's own margin (its
    /// `isOAuthTokenExpired` treats a token as expired 5 minutes early), so a pass that lands just before
    /// expiry never sends a token that dies on the way and shows "sign-in expired" until the next pass.
    static let refreshMargin: TimeInterval = 5 * 60

    /// Whether to refresh before use: there is a refresh token and the provider's expiry is within
    /// `refreshMargin` of `now`. `expiresAt` is always the provider's own expiry, never shortened.
    func needsRefresh(at now: Date) -> Bool {
        guard refreshToken != nil, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(Self.refreshMargin)
    }
}

enum AccountCredential: Codable, Sendable, Equatable {
    case oauth(OAuthTokens)
    case apiKey(String)

    /// Who this credential signs in as, so a login that's already added is spotted: the provider account
    /// a sign-in recorded in `OAuthTokens.identityKey` (Cursor's older sign-ins kept it as `userID`), or
    /// a fingerprint of the API key. `nil` for a sign-in that recorded none.
    var identity: String? {
        switch self {
        case .oauth(let tokens):
            tokens.extras[OAuthTokens.identityKey] ?? tokens.extras["userID"]
        case .apiKey(let key):
            "key:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
