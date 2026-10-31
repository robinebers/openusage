import Foundation

struct ClaudeAccountState {
    let sessions: ClaudeSessions
    var session: ClaudeSession?
    var forcedReadsPending = false
    var restoredPlan: String?
    var restoredResets: MetricLine?
}

extension AccountProviderRuntime {
    /// One usage read per pass, shared with any other card on the same login and never sent inside its
    /// 429 window. The profile and the reset grants are read in the secondary-reads slot instead, apart
    /// from it: Anthropic answers a grants read sent right after a usage read with a 429. A hub account
    /// reads its profile with its first usage read, so it shows its plan as soon as it appears.
    func refreshClaude(_ credential: AccountCredential) async throws -> ProviderUsage {
        let session = claudeSession(for: credential)
        let forced = claude.forcedReadsPending
        claude.forcedReadsPending = false
        if let wait = session.wait(at: now()) { throw ProviderError.rateLimited(retryAfter: wait) }
        let client = ClaudeUsageClient(httpClient: http)
        let (tokens, response) = try await authorizedRead(credential, grant: ClaudeLogin.refresh) { tokens in
            try await session.usage(at: now()) { try await client.fetchUsage(accessToken: tokens.accessToken) }
        }
        var lines = try ClaudeUsageMapper.mapUsageResponse(response)
        if forced {
            if session.resetGrants.isOlder(than: RefreshSetting.forcedResetGrantsMinimumAge, at: now()) {
                await readClaudeResetGrants(session, accessToken: tokens.accessToken)
            }
            try? await readClaudeProfile(session, tokens: tokens)
        } else if account.hub != nil, session.planRead.value == nil, session.planRead.isDue(at: now()) {
            try? await readClaudeProfile(session, tokens: tokens)
        }
        if let resets = claudeResetsLine(session) { lines.append(resets) }
        return ProviderUsage(plan: session.planRead.value, lines: lines)
    }

    func restore(_ snapshot: ProviderSnapshot) {
        guard account.kind == .claude else { return }
        claude.restoredPlan = snapshot.plan
        claude.restoredResets = snapshot.line(label: ClaudeResetGrantStatus.lineLabel)
    }

    func refreshHourlyReads(of snapshot: ProviderSnapshot) async -> ProviderSnapshot? {
        guard account.kind == .claude, let credential = try? await loadCredential() else { return nil }
        let session = claudeSession(for: credential)
        let profileDue = session.planRead.isDue(at: now())
        let grantsDue = session.resetGrants.isOlder(than: RefreshSetting.secondaryReadInterval, at: now())
        guard profileDue || grantsDue, session.wait(at: now()) == nil,
              let tokens = try? await freshTokens(credential, grant: ClaudeLogin.refresh)
        else { return nil }
        if profileDue { try? await readClaudeProfile(session, tokens: tokens) }
        if grantsDue { await readClaudeResetGrants(session, accessToken: tokens.accessToken) }
        var updated = snapshot
        updated.plan = session.planRead.value
        updated.lines.removeAll { $0.label == ClaudeResetGrantStatus.lineLabel }
        if let resets = claudeResetsLine(session) { updated.lines.append(resets) }
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

    private func claudeSession(for credential: AccountCredential) -> ClaudeSession {
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
}
