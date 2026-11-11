import Foundation

struct ClaudeAccountState {
    let sessions: ClaudeSessions
    var session: ClaudeSession?
    var forcedReadsPending = false
    var restoredPlan: String?
    var restoredResets: MetricLine?
    var restoredGrants: ClaudeResetGrantStatus?
}

extension AccountProviderRuntime {
    /// One usage read per pass, shared with any other card on the same login and never sent inside its
    /// 429 window. The reset grants are read right behind it whenever they're due, as claude.ai's usage
    /// page reads them with usage: at most once an hour, and on ⌘R once the last read is 15 minutes old,
    /// since Anthropic answers frequent grants reads with 429s. The profile is read in the secondary-reads
    /// slot; a hub account reads it with its first usage read, so it shows its plan as soon as it appears.
    func refreshClaude(_ credential: AccountCredential) async throws -> ProviderUsage {
        let session = claudeSession(for: credential)
        let forced = claude.forcedReadsPending
        claude.forcedReadsPending = false
        if let wait = session.wait(at: now()) { throw ProviderError.rateLimited(retryAfter: wait) }
        let client = ClaudeUsageClient(httpClient: http)
        let (tokens, response) = try await authorizedRead(credential, grant: ClaudeLogin.refresh) { tokens in
            let request: @MainActor () async throws -> HTTPResponse = { try await client.fetchUsage(accessToken: tokens.accessToken) }
            // Cards on one login share a request to save its budget, but a new sign-in must prove itself.
            return try await isCheckingNewSignIn ? session.send(at: now(), request) : session.usage(at: now(), request)
        }
        var lines = try ClaudeUsageMapper.mapUsageResponse(response)
        let grantsAge = forced ? RefreshSetting.forcedResetGrantsMinimumAge : RefreshSetting.secondaryReadInterval
        if session.resetGrants.isOlder(than: grantsAge, at: now()) {
            try? await readClaudeResetGrants(session, accessToken: tokens.accessToken)
        }
        if session.wait(at: now()) == nil,
           forced || (account.hub != nil && session.planRead.value == nil && session.planRead.isDue(at: now())) {
            try? await readClaudeProfile(session, tokens: tokens)
        }
        if let resets = claudeResetsLine(session) { lines.append(resets) }
        let plan = session.planRead.value
        return ProviderUsage(plan: plan, lines: lines, lineTitles: ClaudeUsageMapper.lineTitles(plan: plan))
    }

    func restoreClaude(_ snapshot: ProviderSnapshot) {
        claude.restoredPlan = snapshot.plan
        claude.restoredResets = snapshot.line(label: ClaudeResetGrantStatus.lineLabel)
        claude.restoredGrants = snapshot.resetGrants
    }

    /// Reads the plan once an hour, apart from the usage read. Every reason a due read doesn't go out is
    /// logged, so a plan that never arrives can be traced.
    func refreshHourlyReads(of snapshot: ProviderSnapshot) async -> ProviderSnapshot? {
        guard account.kind == .claude else { return nil }
        let tag = LogTag.plugin("claude")
        let launched = claude.session == nil ? try? await loadCredential() : nil
        guard let session = claude.session ?? launched.map({ claudeSession(for: $0) }) else {
            AppLog.notice(tag, "\(account.cardID) hourly plan read skipped: no stored sign-in")
            return nil
        }
        guard session.planRead.isDue(at: now()) else { return nil }
        if let wait = session.wait(at: now()) {
            AppLog.notice(tag, "\(account.cardID) hourly plan read skipped: Claude asked to wait \(Int(wait))s")
            return nil
        }
        let tokens: OAuthTokens
        do {
            tokens = try await freshTokens(try await loadCredential(), grant: ClaudeLogin.refresh)
        } catch {
            AppLog.notice(tag, "\(account.cardID) hourly plan read skipped: \(error.localizedDescription)")
            return nil
        }
        try? await readClaudeProfile(session, tokens: tokens)
        var updated = snapshot
        updated.plan = session.planRead.value
        let titles = ClaudeUsageMapper.lineTitles(plan: updated.plan)
        updated.lineTitles = titles.isEmpty ? nil : titles
        return updated == snapshot ? nil : updated
    }

    func readClaudeProfile(_ session: ClaudeSession, tokens: OAuthTokens) async throws {
        do {
            let client = ClaudeUsageClient(httpClient: http)
            let response = try await session.send(at: now()) { try await client.fetchProfile(accessToken: tokens.accessToken) }
            if ProviderError.isAuthFailure(response) { throw ProviderError.signInExpired(.claude) }
            let profile = try ClaudeUsageClient.decodeProfile(response)
            if tokens.extras[OAuthTokens.identityKey] == nil {
                if case .oauth(var stored)? = try? await loadCredential() {
                    stored.extras[OAuthTokens.identityKey] = profile.identity
                    try? await replaceCredential(.oauth(stored))
                }
                claude.sessions.rekey(session, to: profile.identity)
            }
            if let uuid = profile.organization?.uuid, UUID(uuidString: uuid) != nil { session.organizationUUID = uuid }
            session.planRead.record(ClaudeUsageMapper.formatLivePlan(profile: profile), at: now())
        } catch {
            guard !Task.isCancelled else { throw error }
            AppLog.warn(LogTag.plugin("claude"), "plan lookup failed; retrying in an hour: \(error.localizedDescription)")
            session.planRead.record(nil, at: now())
            throw error
        }
    }

    func claudeSession(for credential: AccountCredential) -> ClaudeSession {
        let session = claude.sessions.session(for: credential.identity ?? "card:\(account.cardID)")
        if session.planRead.value == nil, let plan = claude.restoredPlan {
            session.planRead.record(plan, at: now())
            session.planRead.forget()
        }
        claude.session = session
        return session
    }

    private func claudeResetsLine(_ session: ClaudeSession) -> MetricLine? {
        guard let check = session.resetGrants.check else { return claude.restoredResets }
        return check.status?.line(now: now())
    }

    /// The login's last grants answer, or the saved one until this launch reads its own.
    func claudeResetGrants(_ session: ClaudeSession?) -> ClaudeResetGrantStatus? {
        guard let check = session?.resetGrants.check else { return claude.restoredGrants }
        return check.status
    }
}
