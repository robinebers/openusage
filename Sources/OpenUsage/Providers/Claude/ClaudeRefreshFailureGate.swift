import Foundation

/// Throttles how often OpenUsage re-attempts a Claude token refresh after one has failed, so a dead or
/// revoked credential doesn't spawn a delegated-CLI refresh (or a network round-trip) on every periodic
/// refresh. Two failure shapes are distinguished:
///
/// - **Terminal** (`invalid_grant` / session expired): the stored refresh chain is dead and no amount of
///   retrying inside OpenUsage will fix it — only an external `claude` re-login can. So a terminal block
///   has NO time expiry: it stays blocked until the credential fingerprint actually changes (the user
///   re-logged in elsewhere). It is also monotonic — a later transient failure can't downgrade it back
///   to a self-clearing transient block.
/// - **Transient** (network / 5xx / timeout during refresh): the credential may well be fine; the world
///   was briefly unavailable. These back off exponentially (`5min * 2^(n-1)`, capped at 6h) and
///   auto-unblock once the window elapses.
///
/// Either block also clears early when the on-disk credential fingerprint differs from the one captured
/// at failure time (an external re-login wrote new creds), rechecked at most once every 15s so the hot
/// refresh path doesn't re-read the keychain on every tick. State persists to `UserDefaults` so a block
/// survives an app relaunch (a revoked token is still revoked after a restart).
struct ClaudeRefreshFailureGate: Sendable {
    enum BlockStatus: Equatable, Sendable {
        case terminal(reason: String, failures: Int)
        case transient(until: Date, failures: Int)
    }

    /// Persisted state. Serialized as JSON into a single `UserDefaults` key so the whole gate round-trips
    /// atomically. `nil` means "no active block".
    private struct State: Codable, Equatable {
        enum Kind: String, Codable { case terminal, transient }
        var kind: Kind
        var reason: String?
        var failures: Int
        var until: Date?
        var fingerprintAtFailure: ClaudeCredentialFingerprint?
        var lastRecheckAt: Date?
    }

    static let baseTransientCooldown: TimeInterval = 5 * 60
    static let maxTransientCooldown: TimeInterval = 6 * 60 * 60
    static let recheckThrottle: TimeInterval = 15

    private let store: SendableUserDefaults
    private let storageKey: String
    /// Re-reads the CURRENT on-disk credential fingerprint so the gate can tell whether an external
    /// `claude` re-login rotated the creds since the failure. Injectable for tests.
    private let currentFingerprint: @Sendable () -> ClaudeCredentialFingerprint

    private var defaults: UserDefaults { store.defaults }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "claude.refreshGate.state.v1",
        currentFingerprint: @escaping @Sendable () -> ClaudeCredentialFingerprint
    ) {
        self.store = SendableUserDefaults(defaults)
        self.storageKey = storageKey
        self.currentFingerprint = currentFingerprint
    }

    // MARK: - Queries

    /// Whether a refresh should be attempted now. True when there is no active block, when a transient
    /// block's window has elapsed, or when the credential fingerprint has changed since the failure
    /// (throttled to one recheck per 15s).
    func shouldAttempt(now: Date) -> Bool {
        guard let state = loadState() else { return true }

        if case .transient = state.kind, let until = state.until, until <= now {
            return true
        }

        // Fingerprint recheck, throttled. If the creds changed externally, unblock (both kinds).
        if let last = state.lastRecheckAt, now.timeIntervalSince(last) < Self.recheckThrottle {
            return false
        }
        var refreshed = state
        refreshed.lastRecheckAt = now
        let changed = currentFingerprint() != (state.fingerprintAtFailure ?? ClaudeCredentialFingerprint())
        if changed {
            clear()
            return true
        }
        saveState(refreshed)
        return false
    }

    func currentBlockStatus(now: Date) -> BlockStatus? {
        guard let state = loadState() else { return nil }
        switch state.kind {
        case .terminal:
            return .terminal(reason: state.reason ?? "session expired", failures: state.failures)
        case .transient:
            let until = state.until ?? now
            if until <= now { return nil }
            return .transient(until: until, failures: state.failures)
        }
    }

    // MARK: - Mutations

    /// Record a terminal auth failure (e.g. `invalid_grant`). Monotonic: once terminal, a later
    /// transient cannot downgrade it; the failure count only ever climbs. No time expiry — only a
    /// changed fingerprint (external re-login) clears it.
    func recordTerminalAuthFailure(reason: String, now: Date) {
        let previous = loadState()
        let failures = (previous?.failures ?? 0) + 1
        saveState(State(
            kind: .terminal,
            reason: reason,
            failures: failures,
            until: nil,
            fingerprintAtFailure: currentFingerprint(),
            lastRecheckAt: now
        ))
    }

    /// Record a transient failure (network/5xx/timeout). Backs off `5min * 2^(failures-1)`, capped at 6h.
    /// If a terminal block is already in place it is NOT downgraded — the credential is still known dead.
    func recordTransientFailure(now: Date) {
        let previous = loadState()
        if previous?.kind == .terminal {
            // Keep the terminal block, but refresh its fingerprint baseline so a later external re-login
            // can still clear it. Don't reset the failure count downward.
            var kept = previous!
            kept.fingerprintAtFailure = currentFingerprint()
            kept.lastRecheckAt = now
            saveState(kept)
            return
        }
        let failures = (previous?.failures ?? 0) + 1
        let exponent = max(0, failures - 1)
        let cooldown = min(Self.baseTransientCooldown * pow(2, Double(exponent)), Self.maxTransientCooldown)
        saveState(State(
            kind: .transient,
            reason: nil,
            failures: failures,
            until: now.addingTimeInterval(cooldown),
            fingerprintAtFailure: currentFingerprint(),
            lastRecheckAt: now
        ))
    }

    /// Clear all block state after a refresh succeeds.
    func recordSuccess() {
        clear()
    }

    // MARK: - Persistence

    private func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    private func loadState() -> State? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func saveState(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
