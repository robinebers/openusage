import Foundation

/// A Claude login's 429 window. Anthropic budgets its usage endpoint per account (about 30 requests an
/// hour, shared with Claude Code and every other monitor on it) and holds a penalty on its own side for
/// up to an hour, so the window outlives a relaunch and nothing goes to the account inside it.
struct ClaudeRateLimitWindow: Codable, Equatable {
    var until: Date
    /// 429s in a row, so a 429 that names no wait doubles the last one.
    var strikes: Int
}

/// What the cards signed in to one Anthropic login share: its 429 window, the usage read in flight, the
/// reset-grants answer, the hourly profile read and the organization a claim goes to. Anthropic's budget
/// is per account, so two cards for one login spend it once.
@MainActor
final class ClaudeSession {
    fileprivate(set) var key: String
    private unowned let sessions: ClaudeSessions
    private var usageInFlight: Task<HTTPResponse, Error>?
    var resetGrants = ClaudeResetGrantsState()
    /// The plan name from `/api/oauth/profile`, read in the secondary-reads slot.
    var planRead = SecondaryRead<String>()
    /// `organization.uuid` from the last profile read: a claim's URL needs it.
    var organizationUUID: String?

    fileprivate init(key: String, sessions: ClaudeSessions) {
        self.key = key
        self.sessions = sessions
    }

    /// The time left in the login's 429 window at `now`, or `nil` when requests may go out.
    func wait(at now: Date) -> TimeInterval? {
        guard let until = sessions.windows[key]?.until, now < until else { return nil }
        return until.timeIntervalSince(now)
    }

    /// Sends one request to the login unless its 429 window is open. A 429 opens the window for its
    /// Retry-After or the doubling wait (`RefreshBackoff.delay`), whichever is longer, and throws that
    /// wait; a 2xx closes it.
    func send(at now: Date, _ request: @escaping @MainActor () async throws -> HTTPResponse) async throws -> HTTPResponse {
        if let wait = wait(at: now) { throw ProviderError.rateLimited(retryAfter: wait) }
        let response = try await request()
        if response.statusCode == 429 {
            let strikes = (sessions.windows[key]?.strikes ?? 0) + 1
            let wait = max(response.retryAfter(now: now) ?? 0, RefreshBackoff.delay(failures: strikes))
            sessions.setWindow(ClaudeRateLimitWindow(until: now.addingTimeInterval(wait), strikes: strikes), for: key)
            throw ProviderError.rateLimited(retryAfter: wait)
        }
        if (200..<300).contains(response.statusCode) { sessions.setWindow(nil, for: key) }
        return response
    }

    /// The login's usage read: a card that asks while another card's read for the same login is in
    /// flight gets that answer instead of sending its own.
    func usage(at now: Date, _ request: @escaping @MainActor () async throws -> HTTPResponse) async throws -> HTTPResponse {
        if let usageInFlight { return try await usageInFlight.value }
        let task = Task { try await self.send(at: now, request) }
        usageInFlight = task
        defer { usageInFlight = nil }
        return try await task.value
    }
}

/// Every Claude login's session, keyed by the sign-in's identity (or by the card until a profile read
/// records one), with each login's 429 window kept in the app's defaults.
@MainActor
final class ClaudeSessions {
    static let storageKey = "openusage.claudeRateLimits.v1"
    private let defaults: UserDefaults?
    private var sessions: [String: ClaudeSession] = [:]
    fileprivate private(set) var windows: [String: ClaudeRateLimitWindow]

    /// `nil` keeps the windows in memory only, for a runtime built on its own.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        windows = defaults?.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: ClaudeRateLimitWindow].self, from: $0) } ?? [:]
    }

    func session(for key: String) -> ClaudeSession {
        if let session = sessions[key] { return session }
        let session = ClaudeSession(key: key, sessions: self)
        sessions[key] = session
        return session
    }

    /// Files a card's session under the identity its profile read just recorded, so the login's other
    /// cards share it, unless that login already has one.
    func rekey(_ session: ClaudeSession, to identity: String) {
        guard session.key != identity, sessions[identity] == nil else { return }
        sessions[session.key] = nil
        setWindow(nil, for: session.key)
        session.key = identity
        sessions[identity] = session
    }

    fileprivate func setWindow(_ window: ClaudeRateLimitWindow?, for key: String) {
        guard windows[key] != window else { return }
        windows[key] = window
        defaults?.set(try? JSONEncoder().encode(windows), forKey: Self.storageKey)
    }
}
