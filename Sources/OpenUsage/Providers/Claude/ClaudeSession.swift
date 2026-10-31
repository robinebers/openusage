import Foundation

/// A Claude login's 429 window. Anthropic budgets its usage endpoint per account (about 30 requests an
/// hour, shared with Claude Code and every other monitor on it) and holds a penalty on its own side for
/// up to an hour, so the window outlives a relaunch and nothing goes to the account inside it.
struct ClaudeRateLimitWindow: Codable, Equatable {
    var until: Date
    var strikes: Int
}

@MainActor
final class ClaudeSession {
    fileprivate(set) var key: String
    private unowned let sessions: ClaudeSessions
    private var usageInFlight: Task<HTTPResponse, Error>?
    var resetGrants = ClaudeResetGrantsState()
    var planRead = SecondaryRead<String>()
    var organizationUUID: String?

    fileprivate init(key: String, sessions: ClaudeSessions) {
        self.key = key
        self.sessions = sessions
    }

    func wait(at now: Date) -> TimeInterval? {
        guard let until = sessions.windows[key]?.until, now < until else { return nil }
        return until.timeIntervalSince(now)
    }

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

    func usage(at now: Date, _ request: @escaping @MainActor () async throws -> HTTPResponse) async throws -> HTTPResponse {
        if let usageInFlight { return try await usageInFlight.value }
        let task = Task { try await self.send(at: now, request) }
        usageInFlight = task
        defer { usageInFlight = nil }
        return try await task.value
    }
}

@MainActor
final class ClaudeSessions {
    static let storageKey = "openusage.claudeRateLimits.v1"
    private let defaults: UserDefaults?
    private var sessions: [String: ClaudeSession] = [:]
    fileprivate private(set) var windows: [String: ClaudeRateLimitWindow]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let latest = Date().addingTimeInterval(RefreshSetting.failureBackoffCap)
        windows = (defaults?.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: ClaudeRateLimitWindow].self, from: $0) } ?? [:])
            .mapValues { ClaudeRateLimitWindow(until: min($0.until, latest), strikes: $0.strikes) }
    }

    func session(for key: String) -> ClaudeSession {
        if let session = sessions[key] { return session }
        let session = ClaudeSession(key: key, sessions: self)
        sessions[key] = session
        return session
    }

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
