import Foundation

@MainActor
final class AccountProviderRuntime: ProviderRuntime {
    private(set) var account: Account
    private(set) var provider: Provider
    let vault: any CredentialVault
    let http: any HTTPClient
    let now: () -> Date
    /// The plan name (Grok `/settings`, Cursor `GetPlanInfo`), read hourly rather than every pass.
    var planRead = SecondaryRead<String>()
    /// The body the plan comes from (Ollama `/api/me`, the Z.ai subscription, Antigravity
    /// `loadCodeAssist`), read hourly rather than every pass.
    var planBodyRead = SecondaryRead<Data>()
    /// Codex's reset-credit list, for each credit's expiry, read hourly; the count comes from the usage
    /// body every pass.
    var codexResetCreditsRead = SecondaryRead<HTTPResponse>()
    /// Claude's link to its login's session (see `AccountProviderRuntime+ClaudeUsage`).
    var claude: ClaudeAccountState
    /// The Codex credit each claim's idempotency key was matched to (see `AccountProviderRuntime+CodexResets`).
    var codexMatchedCreditIDs: [String: String] = [:]

    init(
        account: Account,
        vault: any CredentialVault,
        http: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping () -> Date = Date.init,
        claudeSessions: ClaudeSessions = ClaudeSessions()
    ) {
        self.account = account
        claude = ClaudeAccountState(sessions: claudeSessions)
        self.vault = vault
        self.http = http
        self.now = now
        provider = Self.provider(for: account)
    }

    /// Picks up a rename without replacing the runtime.
    func update(_ account: Account) {
        self.account = account
        provider = Self.provider(for: account)
    }

    func forgetHourlyReads() {
        planRead.forget()
        planBodyRead.forget()
        codexResetCreditsRead.forget()
        claude.forcedReadsPending = true
    }

    static func provider(for account: Account) -> Provider {
        Provider(id: account.cardID, kind: account.kind, accountLabel: account.label)
    }

    /// The resets popover's claim seam for this account, or `nil` for providers without reset claims.
    /// Claude always spends the grant Anthropic names next, so the picked node's expiry only matters to
    /// Codex.
    func resetClaimService(
        refreshAccount: @escaping @MainActor () async -> WidgetDataStore.RefreshOutcome
    ) -> ResetClaimService? {
        switch account.kind {
        case .claude:
            let status = claude.session?.resetGrants.check?.status
            return ResetClaimService(
                accountID: account.cardID,
                isClaimable: status?.claimableGrantID != nil,
                confirmDetail: status?.confirmDetail,
                claimReset: { [self] _, redeemRequestID in await claimClaudeResetGrant(redeemRequestID: redeemRequestID) },
                refreshAccount: refreshAccount,
                refreshDelay: .seconds(30)
            )
        case .codex:
            return ResetClaimService(
                accountID: account.cardID,
                isClaimable: true,
                confirmDetail: nil,
                claimReset: { [self] expiry, redeemRequestID in
                    await claimCodexResetCredit(expiringAt: expiry, redeemRequestID: redeemRequestID)
                },
                refreshAccount: refreshAccount
            )
        case .cursor, .antigravity, .copilot, .grok, .ollama, .opencodeGo, .openrouter, .zai:
            return nil
        }
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let result = try await refresh(try await loadCredential())
            return ProviderSnapshot(provider: provider, plan: result.plan, lines: result.lines)
        } catch {
            return ProviderSnapshot(provider: provider, failure: RefreshFailure(error: error))
        }
    }

    /// The account's own credential from the vault; the only credential a refresh or claim ever uses.
    func loadCredential() async throws -> AccountCredential {
        guard let credential = try await loadOffMainActor({ [vault, account] in try vault.load(account.id) }) else {
            throw ProviderError.signInExpired(account.kind)
        }
        return credential
    }

    private func refresh(_ credential: AccountCredential) async throws -> ProviderUsage {
        switch account.kind {
        case .claude: try await refreshClaude(credential)
        case .codex: try await refreshCodex(credential)
        case .cursor: try await refreshCursor(credential)
        case .antigravity: try await refreshAntigravity(credential)
        case .copilot: try await refreshCopilot(credential)
        case .grok: try await refreshGrok(credential)
        case .ollama: try await refreshOllama(credential)
        case .opencodeGo: try await refreshOpenCode(credential)
        case .openrouter: try await refreshOpenRouter(credential)
        case .zai: try await refreshZAI(credential)
        }
    }

    /// The account's OAuth tokens, refreshed through the login's own `grant` and saved back to the vault
    /// first when they expire within `OAuthTokens.refreshMargin`.
    func freshTokens(
        _ credential: AccountCredential,
        grant: (String, any HTTPClient, Date) async throws -> OAuthGrant
    ) async throws -> OAuthTokens {
        guard case .oauth(var tokens) = credential else { throw ProviderError.invalidResponse }
        guard tokens.needsRefresh(at: now()), let refreshToken = tokens.refreshToken else { return tokens }
        let granted = try await grant(refreshToken, http, now())
        tokens.accessToken = granted.accessToken
        if let refresh = granted.refreshToken { tokens.refreshToken = refresh }
        tokens.expiresAt = granted.expiresAt
        try await replaceCredential(.oauth(tokens))
        return tokens
    }

    private func refreshCodex(_ credential: AccountCredential) async throws -> ProviderUsage {
        let tokens = try await freshTokens(credential, grant: CodexLogin.refresh)
        let accountID = tokens.extras["chatgpt_account_id"]
        let response = try await CodexUsageClient(http: http).fetchUsage(accessToken: tokens.accessToken, accountID: accountID)
        let resetCredits = await codexResetCredits(after: response, accessToken: tokens.accessToken, accountID: accountID)
        return try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())
    }

    private func refreshCopilot(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .oauth(let tokens) = credential else { throw ProviderError.invalidResponse }
        let response = try await CopilotUsageClient(http: http).fetchUsage(token: tokens.accessToken)
        try ProviderError.requireSuccess(response, kind: .copilot)
        return try CopilotUsageMapper.map(response)
    }

    private func refreshGrok(_ credential: AccountCredential) async throws -> ProviderUsage {
        let tokens = try await freshTokens(credential, grant: GrokLogin.refresh)
        let client = GrokUsageClient(httpClient: http)
        let usage = try await client.fetchCreditsConfig(accessToken: tokens.accessToken)
        let mapped = try GrokUsageMapper.mapCreditsConfig(usage)
        if planRead.isDue(at: now()) {
            let settings = try? await client.fetchSettings(accessToken: tokens.accessToken)
            planRead.record(settings.flatMap(GrokUsageMapper.planName(from:)), at: now())
        }
        return ProviderUsage(plan: planRead.value, lines: mapped.lines)
    }

    private func refreshCursor(_ credential: AccountCredential) async throws -> ProviderUsage {
        var tokens = try await cursorTokens(credential)
        let client = CursorUsageClient(http: http)
        var usageResponse = try await client.fetchUsage(accessToken: tokens.accessToken)
        if ProviderError.isAuthFailure(usageResponse) {
            tokens = try await refreshCursorTokens(tokens)
            usageResponse = try await client.fetchUsage(accessToken: tokens.accessToken)
        }
        try ProviderError.requireSuccess(usageResponse, kind: .cursor)
        guard let usage = ProviderParse.jsonObject(usageResponse.body) else {
            throw ProviderError.invalidResponse
        }
        return try await cursorUsage(usage, client: client, accessToken: tokens.accessToken)
    }

    private func refreshAntigravity(_ credential: AccountCredential) async throws -> ProviderUsage {
        let tokens = try await freshTokens(credential, grant: AntigravityLogin.refresh)
        let client = AntigravityUsageClient(http: http)
        if planBodyRead.isDue(at: now()) {
            planBodyRead.record(try? await client.loadCodeAssist(token: tokens.accessToken), at: now())
        }
        let codeAssist = planBodyRead.value
        let bodies = try await client.quotaSummary(
            token: tokens.accessToken,
            project: codeAssist.flatMap(AntigravityUsageMapper.parseProject)
        )
        guard let lines = AntigravityUsageMapper.parseQuotaSummaries(bodies) else { throw ProviderError.invalidResponse }
        return ProviderUsage(plan: codeAssist.flatMap(AntigravityUsageMapper.parseLoadCodeAssistPlan), lines: lines)
    }

    private func refreshOllama(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let key) = credential else { throw ProviderError.invalidResponse }
        let client = OllamaUsageClient(http: http)
        let balance = try await client.fetchBalance(apiKey: key)
        try ProviderError.requireSuccess(balance, kind: .ollama)
        if planBodyRead.isDue(at: now()) {
            planBodyRead.record(successBody(try? await client.fetchAccount(apiKey: key)), at: now())
        }
        return try OllamaUsageMapper.map(balanceBody: balance.body, accountBody: planBodyRead.value)
    }

    private func refreshOpenCode(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let key) = credential else { throw ProviderError.invalidResponse }
        let response = try await OpenCodeUsageClient(http: http).fetchUsage(apiKey: key)
        if response.statusCode == 403, OpenCodeUsageMapper.errorType(in: response) == "EntitlementError" {
            throw ProviderError.unavailable("No OpenCode Go subscription on this account.")
        }
        try ProviderError.requireSuccess(response, kind: .opencodeGo)
        return ProviderUsage(plan: OpenCodeUsageMapper.plan, lines: try OpenCodeUsageMapper.meterLines(response))
    }

    /// One OpenRouter endpoint's outcome: its `data` object, a rejected key, or the failure the card
    /// would show.
    private enum OpenRouterEndpoint {
        case data([String: Any])
        case keyRejected
        case failed(Error)
    }

    private func openRouterEndpoint(_ call: () async throws -> HTTPResponse) async -> OpenRouterEndpoint {
        do {
            let response = try await call()
            if ProviderError.isAuthFailure(response) { return .keyRejected }
            try ProviderError.requireSuccess(response, kind: .openrouter)
            guard let data = OpenRouterUsageMapper.dataObject(response.body) else {
                return .failed(ProviderError.invalidResponse)
            }
            return .data(data)
        } catch {
            return .failed(error)
        }
    }

    private func refreshOpenRouter(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let key) = credential else { throw ProviderError.invalidResponse }
        let client = OpenRouterUsageClient(http: http)
        let credits = await openRouterEndpoint { try await client.fetchCredits(apiKey: key) }
        let keyInfo = await openRouterEndpoint { try await client.fetchKey(apiKey: key) }
        var lines: [MetricLine] = []
        var plan: String?
        if case .data(let data) = credits {
            lines += OpenRouterUsageMapper.creditsLines(from: data)
        }
        if case .data(let data) = keyInfo {
            let mapped = OpenRouterUsageMapper.keyMetrics(from: data)
            plan = mapped.plan
            lines += mapped.lines
        }
        if !lines.isEmpty { return ProviderUsage(plan: plan, lines: lines) }
        // The key is only invalid when both endpoints reject it: OpenRouter gates some endpoints to
        // specific key types, so a lone 403 is a valid key that cannot read that endpoint.
        if case .keyRejected = credits, case .keyRejected = keyInfo {
            throw ProviderError.signInExpired(.openrouter)
        }
        let failures = [credits, keyInfo].compactMap { outcome -> Error? in
            if case .failed(let error) = outcome { return error }
            return nil
        }
        throw failures.first ?? ProviderError.invalidResponse
    }

    private func refreshZAI(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let key) = credential else { throw ProviderError.invalidResponse }
        let client = ZAIUsageClient(http: http)
        let quota = try await client.fetchQuota(apiKey: key)
        try ProviderError.requireSuccess(quota, kind: .zai)
        if planBodyRead.isDue(at: now()) {
            planBodyRead.record(successBody(try? await client.fetchSubscription(apiKey: key)), at: now())
        }
        return try ZAIUsageMapper.map(quotaBody: quota.body, subscriptionBody: planBodyRead.value)
    }

    /// The body of a best-effort request, `nil` unless it succeeded: a failed plan lookup costs the
    /// plan, never the meters, and its error page never reaches a mapper.
    private func successBody(_ response: HTTPResponse?) -> Data? {
        guard let response, (200..<300).contains(response.statusCode) else { return nil }
        return response.body
    }

    /// Replaces the account's stored credential after a token refresh. The vault only replaces an
    /// existing entry, so a refresh that lands after the account was removed fails here instead of
    /// recreating the credential.
    func replaceCredential(_ credential: AccountCredential) async throws {
        try await loadOffMainActor { [vault, account] in try vault.update(credential, for: account.id) }
    }
}
