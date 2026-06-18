import Foundation

@MainActor
final class GrokProvider: ProviderRuntime {
    let provider = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))

    let authStore: GrokAuthStore
    let usageClient: GrokUsageClient
    let logUsageScanner: GrokLogUsageScanner
    let now: @Sendable () -> Date

    init(
        authStore: GrokAuthStore = GrokAuthStore(),
        usageClient: GrokUsageClient = GrokUsageClient(),
        logUsageScanner: GrokLogUsageScanner = GrokLogUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.logUsageScanner = logUsageScanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "grok.creditsUsed", provider: provider, title: "Monthly", metricLabel: "Credits used"),
            .badge(id: "grok.payAsYouGo", provider: provider, title: "Extra Usage", metricLabel: "Pay as you go")
            // Local spend tiles, estimated from the Grok CLI log (see GrokLogUsageScanner).
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func refresh() async -> ProviderSnapshot {
        do {
            return try await loadAndProbe()
        } catch {
            return ProviderSnapshot.error(provider: provider, message: error.localizedDescription)
        }
    }

    private func loadAndProbe() async throws -> ProviderSnapshot {
        let candidates = try authStore.loadAuthCandidates()
        var sawExpiredCandidate = false

        for var state in candidates {
            if authStore.needsRefresh(entry: state.entry, token: state.token) {
                if let refreshed = await refreshAccessToken(state: &state) {
                    return try await probe(state: &state, accessToken: refreshed)
                }
                if authStore.isExpired(entry: state.entry, token: state.token) {
                    sawExpiredCandidate = true
                    continue
                }
            }
            return try await probe(state: &state, accessToken: state.token)
        }

        if sawExpiredCandidate {
            throw GrokAuthError.expired
        }
        throw GrokAuthError.invalidAuth
    }

    private func probe(state: inout GrokAuthState, accessToken: String) async throws -> ProviderSnapshot {
        let billingResponse = try await fetchBillingWithRetry(accessToken: accessToken, state: &state)
        var mapped = try GrokUsageMapper.mapBillingResponse(billingResponse)
        let plan = await fetchPlanName(accessToken: state.token)

        // Local ccusage-style spend tiles, read natively from the Grok CLI log (no package runner).
        // `scan` is awaited so its whole-file read + parse runs off the main actor.
        if let tokenUsage = await logUsageScanner.scan(daysBack: 30, now: now()) {
            SpendTileMapper.appendTokenUsage(tokenUsage, to: &mapped.lines, now: now())
        }

        return ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: plan,
            lines: mapped.lines,
            refreshedAt: now()
        )
    }

    private func fetchBillingWithRetry(accessToken: String, state: inout GrokAuthState) async throws -> HTTPResponse {
        var working = state
        defer { state = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchBilling(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshed = await self.refreshAccessToken(state: &working) else {
                    throw GrokAuthError.expired
                }
                return refreshed
            },
            connectionFailed: GrokUsageError.connectionFailed,
            authExpired: GrokAuthError.expired
        )
    }

    private func refreshAccessToken(state: inout GrokAuthState) async -> String? {
        guard let refreshToken = authStore.refreshToken(for: state.entry) else {
            return nil
        }

        let response: HTTPResponse
        do {
            response = try await usageClient.refreshToken(
                refreshToken,
                clientID: authStore.clientID(entryKey: state.entryKey, entry: state.entry)
            )
        } catch {
            return nil
        }

        guard (200..<300).contains(response.statusCode),
              let decoded = usageClient.decodeRefreshResponse(response),
              !decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let accessToken = decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        state.token = accessToken
        state.entry.key = accessToken
        if let refreshToken = decoded.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines), !refreshToken.isEmpty {
            state.entry.refreshToken = refreshToken
        }
        if let idToken = decoded.idToken?.trimmingCharacters(in: .whitespacesAndNewlines), !idToken.isEmpty {
            state.entry.idToken = idToken
        }

        let expiresAt = refreshExpiryDate(response: decoded, accessToken: accessToken)
        state.entry.expiresAt = OpenUsageISO8601.string(from: expiresAt)
        try? authStore.save(state)
        return accessToken
    }

    private func refreshExpiryDate(response: GrokRefreshResponse, accessToken: String) -> Date {
        if let expiresIn = response.expiresIn, expiresIn.isFinite, expiresIn > 0 {
            return now().addingTimeInterval(expiresIn)
        }
        if let tokenExpiry = authStore.tokenExpiresAt(accessToken) {
            return tokenExpiry
        }
        return now().addingTimeInterval(60 * 60)
    }

    private func fetchPlanName(accessToken: String) async -> String? {
        do {
            return GrokUsageMapper.planName(from: try await usageClient.fetchSettings(accessToken: accessToken))
        } catch {
            return nil
        }
    }
}
