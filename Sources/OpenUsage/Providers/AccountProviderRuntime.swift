import Foundation

@MainActor
final class AccountProviderRuntime: ProviderRuntime {
    private(set) var account: Account
    private(set) var provider: Provider
    let vault: any CredentialVault
    let http: any HTTPClient
    let now: () -> Date
    var planRead = SecondaryRead<String>()
    var planBodyRead = SecondaryRead<Data>()
    var codexResetCreditsRead = SecondaryRead<HTTPResponse>()
    var cursorMembershipRead = SecondaryRead<String>()
    var cursorSpendDays: [Date: CursorSpendDay] = [:]
    var claude: ClaudeAccountState
    var codexMatchedCreditIDs: [String: String] = [:]
    /// One renewal at a time: a provider that rotates refresh tokens refuses a second renewal sent with
    /// the same one, so a caller that needs a renewal while one is in flight waits for its tokens, and a
    /// caller whose tokens another renewal already replaced takes the stored ones.
    private var renewal: Task<OAuthTokens, Error>?

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

    func update(_ account: Account) {
        self.account = account
        provider = Self.provider(for: account)
    }

    func forgetHourlyReads() {
        planRead.forget()
        planBodyRead.forget()
        codexResetCreditsRead.forget()
        cursorMembershipRead.forget()
        claude.forcedReadsPending = true
    }

    static func provider(for account: Account) -> Provider {
        Provider(
            id: account.cardID, kind: account.kind, accountLabel: account.label, organization: account.organization,
            hubHost: account.hub?.host
        )
    }

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
                refreshAccount: refreshAccount
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
        case .cursor, .antigravity, .copilot, .devin, .grok, .ollama, .opencodeGo, .openrouter, .zai:
            return nil
        }
    }

    func refresh() async -> Result<ProviderSnapshot, RefreshFailure> {
        do {
            let usage = try await refresh(try await loadCredential())
            let disabled = account.hub.flatMap { $0.isDisabled ? "This login is disabled on the CLIProxyAPI hub at \($0.host)." : nil }
            return .success(ProviderSnapshot(provider: provider, plan: usage.plan, lines: usage.lines, notice: disabled ?? usage.notice))
        } catch {
            return .failure(RefreshFailure(error: error))
        }
    }

    func loadCredential() async throws -> AccountCredential {
        guard let credential = try await loadOffMainActor({ [vault, account] in try vault.load(account.id) }) else {
            throw refusedCredential
        }
        return credential
    }

    /// A refused sign-in has to be added again; a refused key or token can be replaced on the page; a
    /// hub's login is fixed on the hub.
    private var refusedCredential: ProviderError {
        if let hub = account.hub {
            return .unavailable("The CLIProxyAPI hub at \(hub.host) has no working sign-in for this login. Sign it in again on the hub.")
        }
        return switch account.authMethod {
        case .oauth: .signInExpired(account.kind)
        case .apiKey: .keyRejected("\(account.kind.displayName) rejected the API key.")
        case .organizationToken: .keyRejected("GitHub rejected the token.")
        }
    }

    private func refresh(_ credential: AccountCredential) async throws -> ProviderUsage {
        do {
            return switch account.kind {
            case .claude: try await refreshClaude(credential)
            case .codex: try await refreshCodex(credential)
            case .cursor: try await refreshCursor(credential)
            case .antigravity: try await refreshAntigravity(credential)
            case .copilot: try await refreshCopilot(credential)
            case .devin: try await refreshDevin(credential)
            case .grok: try await refreshGrok(credential)
            case .ollama: try await refreshOllama(credential)
            case .opencodeGo: try await refreshOpenCode(credential)
            case .openrouter: try await refreshOpenRouter(credential)
            case .zai: try await refreshZAI(credential)
            }
        } catch ProviderError.signInExpired {
            throw refusedCredential
        }
    }

    func freshTokens(
        _ credential: AccountCredential,
        grant: @escaping @Sendable (String, any HTTPClient, Date) async throws -> OAuthGrant
    ) async throws -> OAuthTokens {
        guard case .oauth(let tokens) = credential else { throw ProviderError.invalidResponse }
        guard tokens.needsRefresh(at: now()), let expiresAt = tokens.expiresAt else { return tokens }
        do {
            return try await renewedTokens(tokens, grant: grant)
        } catch let error where expiresAt > now() {
            AppLog.warn(.auth, "\(account.cardID) early token renewal failed; keeping the current token: \(error.localizedDescription)")
            return tokens
        }
    }

    /// The usage read with the sign-in renewed once when the provider refuses the access token (401):
    /// a token whose expiry the login never reported, or one the provider cut short, is renewed through
    /// the account's own refresh token and the read retried; a second 401 is the expired sign-in. No
    /// other answer renews.
    func authorizedRead(
        _ credential: AccountCredential,
        grant: @escaping @Sendable (String, any HTTPClient, Date) async throws -> OAuthGrant,
        read: (OAuthTokens) async throws -> HTTPResponse
    ) async throws -> (tokens: OAuthTokens, response: HTTPResponse) {
        var tokens = try await freshTokens(credential, grant: grant)
        var response = try await read(tokens)
        guard response.statusCode == 401, tokens.refreshToken != nil else { return (tokens, response) }
        AppLog.debug(.auth, "\(account.cardID) usage read unauthorized; renewing the sign-in once")
        tokens = try await renewedTokens(tokens, grant: grant)
        response = try await read(tokens)
        return (tokens, response)
    }

    private func renewedTokens(
        _ tokens: OAuthTokens,
        grant: @escaping @Sendable (String, any HTTPClient, Date) async throws -> OAuthGrant
    ) async throws -> OAuthTokens {
        if let renewal { return try await renewal.value }
        guard let refreshToken = tokens.refreshToken else { return tokens }
        let renewal = Task {
            defer { self.renewal = nil }
            if case .oauth(let stored)? = try? await loadCredential(), stored.accessToken != tokens.accessToken { return stored }
            var tokens = tokens
            let granted = try await grant(refreshToken, http, now())
            tokens.accessToken = granted.accessToken
            if let refresh = granted.refreshToken { tokens.refreshToken = refresh }
            tokens.expiresAt = granted.expiresAt
            try await replaceCredential(.oauth(tokens))
            return tokens
        }
        self.renewal = renewal
        return try await renewal.value
    }

    private func refreshCodex(_ credential: AccountCredential) async throws -> ProviderUsage {
        let (tokens, response) = try await authorizedRead(credential, grant: CodexLogin.refresh) { tokens in
            try await CodexUsageClient(http: http).fetchUsage(accessToken: tokens.accessToken, accountID: tokens.extras["chatgpt_account_id"])
        }
        let accountID = tokens.extras["chatgpt_account_id"]
        let resetCredits = await codexResetCredits(after: response, accessToken: tokens.accessToken, accountID: accountID)
        return try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())
    }

    private func refreshCopilot(_ credential: AccountCredential) async throws -> ProviderUsage {
        if let organization = account.organization {
            guard case .apiKey(let token) = credential else { throw ProviderError.invalidResponse }
            return ProviderUsage(plan: nil, lines: try await CopilotUsageClient(http: http).organizationUsage(organization, token: token))
        }
        guard case .oauth(let tokens) = credential else { throw ProviderError.invalidResponse }
        let response = try await CopilotUsageClient(http: http).fetchUsage(token: tokens.accessToken)
        try ProviderError.requireSuccess(response, kind: .copilot)
        return try CopilotUsageMapper.map(response)
    }

    private func refreshDevin(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .oauth(let tokens) = credential else { throw ProviderError.invalidResponse }
        let response = try await DevinUsageClient(http: http).fetchUserStatus(tokens)
        try ProviderError.requireSuccess(response, kind: .devin)
        return try DevinUsageMapper.map(response.body)
    }

    private func refreshGrok(_ credential: AccountCredential) async throws -> ProviderUsage {
        let client = GrokUsageClient(httpClient: http)
        let (tokens, usage) = try await authorizedRead(credential, grant: GrokLogin.refresh) { tokens in
            try await client.fetchCreditsConfig(accessToken: tokens.accessToken)
        }
        let mapped = try GrokUsageMapper.mapCreditsConfig(usage)
        if planRead.isDue(at: now()) {
            let settings = try? await client.fetchSettings(accessToken: tokens.accessToken)
            planRead.record(settings.flatMap(GrokUsageMapper.planName(from:)), at: now())
        }
        return ProviderUsage(plan: planRead.value, lines: mapped.lines, notice: mapped.notice)
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

    private func successBody(_ response: HTTPResponse?) -> Data? {
        guard let response, (200..<300).contains(response.statusCode) else { return nil }
        return response.body
    }

    func replaceCredential(_ credential: AccountCredential) async throws {
        try await loadOffMainActor { [vault, account] in try vault.update(credential, for: account.id) }
    }

    func validate(_ credential: AccountCredential) async throws {
        _ = try await refresh(credential)
    }
}
