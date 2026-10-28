import Foundation

/// A Claude account's link to its login's `ClaudeSession`, carried across refreshes.
struct ClaudeAccountState {
    let sessions: ClaudeSessions
    /// The session of the login the last refresh signed in as.
    var session: ClaudeSession?
    /// Set by ⌘R: the next refresh also reads the profile, and the reset grants once the last check is
    /// older than `RefreshSetting.forcedResetGrantsMinimumAge`.
    var forcedReadsPending = false
    /// The plan and the Rate Limit Resets row of the snapshot shown before the first refresh, kept until
    /// the login's own reads answer.
    var restoredPlan: String?
    var restoredResets: MetricLine?
}

extension AccountProviderRuntime {
    /// One usage read per pass, shared with any other card on the same login and never sent inside its
    /// 429 window. The profile and the reset grants are read in the secondary-reads slot instead, apart
    /// from it: Anthropic answers a grants read sent right after a usage read with a 429.
    func refreshClaude(_ credential: AccountCredential) async throws -> ProviderUsage {
        let session = claudeSession(for: credential)
        let forced = claude.forcedReadsPending
        claude.forcedReadsPending = false
        if let wait = session.wait(at: now()) { throw ProviderError.rateLimited(retryAfter: wait) }
        let tokens = try await freshTokens(credential, grant: ClaudeLogin.refresh)
        let client = ClaudeUsageClient(httpClient: http)
        let response = try await session.usage(at: now()) { try await client.fetchUsage(accessToken: tokens.accessToken) }
        var lines = try ClaudeUsageMapper.mapUsageResponse(response)
        if forced {
            if session.resetGrants.isOlder(than: RefreshSetting.forcedResetGrantsMinimumAge, at: now()) {
                await readClaudeResetGrants(session, accessToken: tokens.accessToken)
            }
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

    /// The secondary-reads slot: the hourly profile and reset-grants reads, so the launch pass and every
    /// later one cost the login a single usage request.
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

    /// The login's profile: its plan name, the organization a claim goes to, and the sign-in's identity
    /// for an account added before sign-ins recorded it, so a later sign-in to the same Claude account is
    /// caught and its cards share one session. A failed read keeps the last plan for the hour.
    func readClaudeProfile(_ session: ClaudeSession, tokens: OAuthTokens) async throws {
        do {
            let client = ClaudeUsageClient(httpClient: http)
            let response = try await session.send(at: now()) { try await client.fetchProfile(accessToken: tokens.accessToken) }
            if ProviderError.isAuthFailure(response) { throw ProviderError.signInExpired(.claude) }
            let profile = try ClaudeUsageClient.decodeProfile(response)
            if tokens.extras[OAuthTokens.identityKey] == nil {
                var identified = tokens
                identified.extras[OAuthTokens.identityKey] = profile.identity
                try? await replaceCredential(.oauth(identified))
                claude.sessions.rekey(session, to: profile.identity)
            }
            if let uuid = profile.organization?.uuid, UUID(uuidString: uuid) != nil { session.organizationUUID = uuid }
            session.planRead.record(ClaudeUsageMapper.formatLivePlan(profile: profile), at: now())
        } catch {
            AppLog.warn(LogTag.plugin("claude"), "plan lookup failed; retrying in an hour: \(error.localizedDescription)")
            session.planRead.record(nil, at: now())
            throw error
        }
    }

    /// The session of the login `credential` signs in as, or the card's own until a profile read records
    /// the identity. A new session starts from the restored plan, so the label stays until the slot.
    private func claudeSession(for credential: AccountCredential) -> ClaudeSession {
        let session = claude.sessions.session(for: credential.identity ?? "card:\(account.cardID)")
        if session.planRead.value == nil, let plan = claude.restoredPlan {
            session.planRead.record(plan, at: now())
            session.planRead.forget()
        }
        claude.session = session
        return session
    }

    /// The Rate Limit Resets row from the login's last check, or the restored one before any check.
    private func claudeResetsLine(_ session: ClaudeSession) -> MetricLine? {
        guard let check = session.resetGrants.check else { return claude.restoredResets }
        return check.status?.line(now: now())
    }
}
