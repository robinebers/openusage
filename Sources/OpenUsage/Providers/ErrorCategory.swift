import Foundation

/// A stable, machine-readable bucket for a refresh failure, so telemetry can group "what kind of
/// errors happen" without sending the free-form (localized, user-facing) error message — which is not
/// groupable and risks leaking detail. Every provider error enum maps its cases to one of these via
/// `CategorizedError`; the raw values are the strings reported to telemetry, so keep them stable.
///
/// `notLoggedIn` is split out deliberately: a large share of refresh "failures" are simply providers
/// the user has not authenticated, which is expected noise rather than a bug — keeping it as its own
/// category lets analysis filter it out.
enum ErrorCategory: String, Sendable, CaseIterable, Codable {
    case notLoggedIn = "not_logged_in"
    /// A previously-valid credential went bad (expired / revoked / conflicting session).
    case authExpired = "auth_expired"
    /// Auth is structurally wrong rather than stale (bad payload, misconfigured OAuth URL, unsupported key).
    case authInvalid = "auth_invalid"
    /// Local credential material exists, but its file, database, or Keychain entry could not be read.
    case credentialAccess = "credential_access"
    /// The request never completed (transport / connection failure).
    case network = "network"
    /// A response came back but could not be parsed / a required field was missing.
    case decoding = "decoding"
    case http4xx = "http_4xx"
    case http5xx = "http_5xx"
    case rateLimited = "rate_limited"
    /// Usage data is legitimately unavailable for this account/plan (no subscription, API-key-only, quota
    /// endpoint absent) — not a malfunction.
    case notAvailable = "not_available"
    case other = "other"

    /// Classify a non-2xx HTTP status. 429 is called out as rate limiting; everything else splits on the
    /// 4xx/5xx boundary.
    static func http(_ statusCode: Int) -> ErrorCategory {
        switch statusCode {
        case 429: return .rateLimited
        case 400..<500: return .http4xx
        case 500..<600: return .http5xx
        default: return .other
        }
    }
}

/// An error that knows its own telemetry bucket. Conformed by every provider error enum below so the
/// classification lives next to the cases it describes and stays exhaustive as cases are added.
protocol CategorizedError: Error {
    var errorCategory: ErrorCategory { get }
}

// MARK: - Provider conformances
//
// Retroactive conformances kept in one file so the full mapping is reviewable at a glance and a new
// error case forces a compile error here (exhaustive switches) rather than silently falling to `.other`.

extension ClaudeAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .sessionExpired, .tokenExpired, .desktopTokenExpired: .authExpired
        case .invalidOAuthURL, .desktopCredentialsUnavailable: .authInvalid
        case .desktopPermissionRequired: .credentialAccess
        case .credentialsChanged: .other
        }
    }
}

extension ClaudeUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        }
    }
}

extension CodexAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .sessionExpired, .tokenConflict, .tokenRevoked, .tokenExpired: .authExpired
        case .usageAPIKey: .notAvailable
        case .invalidAuthPayload: .authInvalid
        }
    }
}

extension CodexUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        }
    }
}

extension CursorAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .sessionExpired, .tokenExpired: .authExpired
        }
    }
}

extension CursorUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse, .totalUsageLimitMissing: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        case .requestBasedUnavailable, .noActiveSubscription: .notAvailable
        case .usageAfterRefreshFailed: .other
        }
    }
}

extension GrokAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .invalidAuth: .authInvalid
        case .expired: .authExpired
        }
    }
}

extension GrokUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        }
    }
}

extension DevinAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        }
    }
}

extension DevinUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .invalidResponse: .decoding
        case .quotaUnavailable: .notAvailable
        }
    }
}

extension CopilotAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .tokenInvalid: .authExpired
        }
    }
}

extension CopilotUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        case .quotaUnavailable: .notAvailable
        }
    }
}

extension OpenCodeUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notLoggedIn: .notLoggedIn
        case .credentialsUnreadable, .databaseUnreadable: .credentialAccess
        }
    }
}

extension OpenRouterAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .missingKey: .notLoggedIn
        case .invalidKey: .authInvalid
        case .saveFailed, .deleteFailed: .other
        }
    }
}

extension OpenRouterUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        }
    }
}

extension ZAIAuthError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .missingKey: .notLoggedIn
        case .invalidKey: .authInvalid
        case .saveFailed, .deleteFailed: .other
        }
    }
}

extension ZAIUsageError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .connectionFailed: .network
        case .invalidResponse: .decoding
        case .requestFailed(let status): ErrorCategory.http(status)
        case .noCodingPlan: .notAvailable
        }
    }
}

extension HTTPClientError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .invalidResponse: .decoding
        }
    }
}

extension AntigravityError: CategorizedError {
    var errorCategory: ErrorCategory {
        switch self {
        case .notSignedIn: .notLoggedIn
        case .credentialStoreUnreadable: .credentialAccess
        case .invalidCredentialData: .authInvalid
        case .authExpired: .authExpired
        case .unavailable: .network
        }
    }
}
