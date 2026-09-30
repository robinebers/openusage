import XCTest
@testable import OpenUsage

/// Shared JWT / auth.json builders for the Codex multi-account suites.
enum CodexMultiAccountFixtures {
    static let home = URL(fileURLWithPath: "/Users/dev")

    static func b64url(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A ChatGPT-shaped JWT. `accountID` lands in the `auth` claim, `email` in the `profile` claim.
    static func token(accountID: String? = nil, email: String? = nil, exp: Date? = nil) -> String {
        var claims: [String] = []
        if let accountID {
            claims.append(#""https://api.openai.com/auth":{"chatgpt_account_id":"\#(accountID)","chatgpt_plan_type":"pro"}"#)
        }
        if let email {
            claims.append(#""https://api.openai.com/profile":{"email":"\#(email)"}"#)
        }
        if let exp { claims.append(#""exp":\#(Int(exp.timeIntervalSince1970))"#) }
        return "\(b64url(#"{"alg":"RS256"}"#)).\(b64url("{\(claims.joined(separator: ","))}")).sig"
    }

    /// A Codex `auth.json`. The id_token carries `accountID`/`email`; the access token carries
    /// `accessAccountID ?? accountID` unless a full `accessToken` is supplied.
    static func codexAuth(
        accountID: String?,
        email: String,
        accessAccountID: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = "rt"
    ) -> String {
        let auth = CodexAuth(
            tokens: CodexTokens(
                accessToken: accessToken ?? token(accountID: accessAccountID ?? accountID, email: email),
                refreshToken: refreshToken,
                idToken: token(accountID: accountID, email: email),
                accountID: accountID
            ),
            lastRefresh: nil,
            apiKey: nil
        )
        return String(decoding: try! JSONEncoder().encode(auth), as: UTF8.self)
    }

    /// pi's `auth.json` with one `oauth` entry per provider id.
    static func piAuth(_ entries: [(provider: String, accountID: String, email: String)]) -> String {
        let body = entries.map { entry in
            #""\#(entry.provider)":{"type":"oauth","access":"\#(token(accountID: entry.accountID, email: entry.email))","refresh":"rt","accountId":"\#(entry.accountID)"}"#
        }.joined(separator: ",")
        return "{\(body)}"
    }

    static func usageResponse(usedPercent: Int = 10) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":\#(usedPercent),"limit_window_seconds":18000}}}"#.utf8))
    }
}

@MainActor
extension XCTestCase {
    /// A throwaway `UserDefaults` suite, wiped again at teardown.
    func makeScratchDefaults(_ prefix: String = "CodexMultiAccount") -> UserDefaults {
        let suiteName = "OpenUsageTests.\(prefix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
