import Foundation

@MainActor
final class AccountProviderRuntime: ProviderRuntime {
    private(set) var account: Account
    private(set) var provider: Provider
    private(set) var vault: any CredentialVault
    let http: any HTTPClient
    let now: () -> Date
    var planRead = SecondaryRead<String>()
    var planBodyRead = SecondaryRead<Data>()
    var codexResetCreditsRead = SecondaryRead<HTTPResponse>()
    var zaiResetsRead = SecondaryRead<[ZAIReset]>()
    var cursorMembershipRead = SecondaryRead<String>()
    let usageLedger = UsageLedger()
    let codexCreditsLedger = UsageLedger()
    var claude: ClaudeAccountState
    var codexMatchedCreditIDs: [String: String] = [:]
    var museLastKnown: [MetricLine] = []
    /// One renewal at a time: a provider that rotates refresh tokens refuses a second renewal sent with
    /// the same one, so a caller that needs a renewal while one is in flight waits for its tokens, and a
    /// caller whose tokens another renewal already replaced takes the stored ones.
    private var renewal: Task<OAuthTokens, Error>?
    /// Tokens a renewal granted that the Keychain refused to save. The provider may already have spent
    /// the refresh token they replace, so they stand in for the stored credential until they are saved.
    private var unsavedRenewal: OAuthTokens?
    private var renewalsStopped = false
    /// Set while a new sign-in is proving itself, so nothing else's answer can stand in for its own.
    var isCheckingNewSignIn = false
    private var credentialWrite: Task<Void, Error>?
    /// A token endpoint that rate-limited an early renewal is not asked again for an early one before this.
    private var earlyRenewalNotBefore = Date.distantPast
    /// One Keychain read at a time: a read that blocks, on a prompt nobody answers, holds a thread until
    /// it returns, so a later caller waits for that read instead of blocking another thread. A caller
    /// after a write waits for a read started before it to end, then reads again.
    private var credentialLoad: (task: Task<AccountCredential?, Error>, writes: Int)?
    private var credentialWrites = 0

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
        zaiResetsRead.forget()
        cursorMembershipRead.forget()
        usageLedger.forgetLastRead()
        codexCreditsLedger.forgetLastRead()
        claude.forcedReadsPending = true
    }

    static func provider(for account: Account) -> Provider {
        Provider(
            id: account.cardID, kind: account.kind, accountLabel: account.label, organization: account.organization,
            domain: account.domain, hubHost: account.hub?.host
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
        case .zai:
            return ResetClaimService(
                accountID: account.cardID,
                isClaimable: false,
                confirmDetail: nil,
                claimReset: nil,
                refreshAccount: refreshAccount,
                windowResets: unexpiredZAIResets ?? [],
                claimWindowReset: { [self] reset, requestID in await claimZAIReset(reset, requestID: requestID) }
            )
        case .cursor, .antigravity, .copilot, .devin, .grok, .muse, .ollama, .opencodeGo, .openrouter:
            return nil
        }
    }

    func restore(_ snapshot: ProviderSnapshot) {
        switch account.kind {
        case .claude: restoreClaude(snapshot)
        case .muse: museLastKnown = snapshot.lines
        case .codex, .cursor, .antigravity, .copilot, .devin, .grok, .ollama, .opencodeGo, .openrouter, .zai: break
        }
    }

    func refresh() async -> Result<ProviderSnapshot, RefreshFailure> {
        do {
            return .success(try await readSnapshot(using: loadCredential()))
        } catch {
            return .failure(RefreshFailure(error: error))
        }
    }

    func loadCredential() async throws -> AccountCredential {
        if let unsavedRenewal {
            await saveRenewal(unsavedRenewal)
            return .oauth(unsavedRenewal)
        }
        while let stale = credentialLoad?.task, credentialLoad?.writes != credentialWrites {
            _ = try? await stale.value
            if credentialLoad?.task == stale { credentialLoad = nil }
        }
        let load = credentialLoad?.task ?? Task { try await loadOffMainActor { [vault, account] in try vault.load(account.id) } }
        credentialLoad = (load, credentialWrites)
        defer { if credentialLoad?.task == load { credentialLoad = nil } }
        guard let credential = try await load.value else { throw refusedCredential }
        return credential
    }

    /// A refused sign-in has to be added again; a refused key or token can be replaced on the page; a
    /// hub's login is fixed on the hub.
    private var refusedCredential: ProviderError {
        if let hub = account.hub {
            return HubRefusal.noToken.error(host: hub.host, upstream: nil)
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
            case .muse: try await refreshMuse(credential)
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
        guard !earlyRenewalIsHeld(expiresAt: expiresAt) else { return tokens }
        do {
            return try await renewedTokens(tokens, grant: grant)
        } catch let error where expiresAt > now() {
            holdEarlyRenewal(after: error)
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
            await saveRenewal(tokens)
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
        var usage = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits, now: now())
        let countsSource = CodexHistorySource(
            client: CodexUsageClient(http: http), accessToken: tokens.accessToken, chatGPTAccountID: accountID,
            cardID: account.cardID, report: .counts
        )
        let planType = ProviderParse.jsonObject(response.body)?["plan_type"] as? String
        if let report = CodexHistorySource.Report.workspaceCredits(for: planType) {
            var creditsSource = countsSource
            creditsSource.report = report
            async let counted = refreshHistory(using: countsSource)
            let credits = await refreshHistory(using: creditsSource, ledger: codexCreditsLedger)
            usage.history = await counted.map { CodexUsageReports.combining($0, with: credits) }
        } else {
            usage.history = await refreshHistory(using: countsSource)
        }
        return usage
    }

    private func refreshCopilot(_ credential: AccountCredential) async throws -> ProviderUsage {
        if let organization = account.organization {
            guard case .apiKey(let token) = credential else { throw ProviderError.invalidResponse }
            return ProviderUsage(plan: nil, lines: try await CopilotUsageClient(http: http).organizationUsage(organization, token: token))
        }
        guard case .oauth(let tokens) = credential else { throw ProviderError.invalidResponse }
        let response = try await CopilotUsageClient(http: http).fetchUsage(token: tokens.accessToken, domain: GitHubDomain(saved: account.domain))
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

    private func refreshMuse(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .oauth(let tokens) = credential else { throw ProviderError.invalidResponse }
        let account = try await MuseUsageClient(http: http).account(token: tokens.accessToken)
        let usage = try MuseUsageMapper.map(account, lastKnown: museLastKnown, now: now())
        museLastKnown = usage.lines
        return usage
    }

    private func refreshCursor(_ credential: AccountCredential) async throws -> ProviderUsage {
        var tokens = try await cursorTokens(credential)
        let client = CursorUsageClient(http: http)
        var usageResponse = try await client.fetchUsage(accessToken: tokens.accessToken)
        if ProviderError.isAuthFailure(usageResponse) {
            tokens = try await refreshCursorTokens(tokens)
            usageResponse = try await client.fetchUsage(accessToken: tokens.accessToken)
        }
        let usage = try ProviderError.requireSuccessJSON(usageResponse, kind: .cursor)
        return try await cursorUsage(usage, client: client, accessToken: tokens.accessToken)
    }

    /// Antigravity's usage read with the sign-in renewed once on a 401, the way `authorizedRead` does it
    /// for one response: a second 401 is the expired sign-in.
    private func refreshAntigravity(_ credential: AccountCredential) async throws -> ProviderUsage {
        let tokens = try await freshTokens(credential, grant: AntigravityLogin.refresh)
        do {
            return try await antigravityUsage(token: tokens.accessToken)
        } catch is AntigravityUsageClient.TokenRefused {
            AppLog.debug(.auth, "\(account.cardID) usage read unauthorized; renewing the sign-in once")
            let renewed = try await renewedTokens(tokens, grant: AntigravityLogin.refresh)
            do {
                return try await antigravityUsage(token: renewed.accessToken)
            } catch is AntigravityUsageClient.TokenRefused {
                throw ProviderError.signInExpired(.antigravity)
            }
        }
    }

    private func antigravityUsage(token: String) async throws -> ProviderUsage {
        let client = AntigravityUsageClient(http: http)
        if planBodyRead.isDue(at: now()), let codeAssist = try? await client.loadCodeAssist(token: token) {
            planBodyRead.record(codeAssist, at: now())
        }
        let codeAssist = planBodyRead.value
        let bodies = try await client.quotaSummary(
            token: token,
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
        var usage = try OllamaUsageMapper.map(balanceBody: balance.body, accountBody: planBodyRead.value)
        usage.history = await refreshHistory(using: OllamaHistorySource(client: client, apiKey: key, accountID: account.cardID))
        return usage
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
        var usage = try ZAIUsageMapper.map(quotaBody: quota.body, subscriptionBody: planBodyRead.value)
        if let resets = await zaiResets(apiKey: key) {
            usage.lines.append(ZAIResetsMapper.line(resets))
        }
        return usage
    }

    private func successBody(_ response: HTTPResponse?) -> Data? {
        guard let response, (200..<300).contains(response.statusCode) else { return nil }
        return response.body
    }

    /// Writes run one at a time, so `stopRenewals` can wait out whichever is underway.
    func replaceCredential(_ credential: AccountCredential) async throws {
        guard !renewalsStopped else { return }
        let previous = credentialWrite
        let write = Task { [vault, account] in
            _ = await previous?.result
            try await loadOffMainActor { try vault.update(credential, for: account.id) }
        }
        credentialWrite = write
        try await write.value
        credentialWrites += 1
        if case .oauth(let saved) = credential, saved.accessToken == unsavedRenewal?.accessToken { unsavedRenewal = nil }
    }

    func earlyRenewalIsHeld(expiresAt: Date) -> Bool {
        expiresAt > now() && now() < earlyRenewalNotBefore
    }

    func holdEarlyRenewal(after error: Error) {
        guard case ProviderError.rateLimited(let retryAfter?) = error else { return }
        earlyRenewalNotBefore = now().addingTimeInterval(retryAfter)
    }

    /// Lets a renewal or write that's underway finish, and saves nothing after it, so neither can overwrite
    /// the sign-in replacing this runtime. `resumeRenewals` undoes it if the replacement doesn't go through.
    func stopRenewals() async {
        renewalsStopped = true
        renewal?.cancel()
        _ = try? await renewal?.value
        _ = await credentialWrite?.result
    }

    /// Moves a runtime that proved a new sign-in onto the store that now holds it.
    func adopt(_ vault: any CredentialVault) {
        self.vault = vault
        isCheckingNewSignIn = false
    }

    func resumeRenewals() {
        renewalsStopped = false
    }

    func saveRenewal(_ tokens: OAuthTokens) async {
        unsavedRenewal = tokens
        do {
            try await replaceCredential(.oauth(tokens))
        } catch {
            AppLog.error(.auth, "\(account.cardID) couldn't save the renewed sign-in; keeping it and retrying: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func readSnapshot(using credential: AccountCredential) async throws -> ProviderSnapshot {
        let usage = try await refresh(credential)
        var snapshot = ProviderSnapshot(provider: provider, plan: usage.plan, lines: usage.lines, notice: usage.notice)
        snapshot.lineTitles = usage.lineTitles.isEmpty ? nil : usage.lineTitles
        HistoryRow.append(to: &snapshot, for: widgetDescriptors, in: usage.history)
        return snapshot
    }
}
