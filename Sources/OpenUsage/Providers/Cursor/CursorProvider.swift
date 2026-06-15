import Foundation

@MainActor
final class CursorProvider: ProviderRuntime {
    let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))

    let authStore: CursorAuthStore
    let usageClient: CursorUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        usageClient: CursorUsageClient = CursorUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedDollars(id: "cursor.credits", provider: provider, title: "Credits", limit: 100),
            .percent(id: "cursor.usage", provider: provider, title: "Total Usage", metricLabel: "Total usage"),
            .boundedCount(id: "cursor.requests", provider: provider, title: "Requests", limit: 500,
                          suffix: "requests", periodDurationMs: CursorUsageMapper.billingPeriodMs),
            .percent(id: "cursor.auto", provider: provider, title: "Auto Limits", metricLabel: "Auto usage"),
            .percent(id: "cursor.api", provider: provider, title: "API Usage", metricLabel: "API usage"),
            .boundedDollars(id: "cursor.onDemand", provider: provider, title: "Extra Usage", metricLabel: "On-demand", limit: 100),
            .spend(id: "cursor.today", provider: provider, title: "Today"),
            .spend(id: "cursor.yesterday", provider: provider, title: "Yesterday"),
            .spend(id: "cursor.last30", provider: provider, title: "Last 30 Days")
        ]
    }

    func refresh() async -> ProviderSnapshot {
        guard let state = authStore.loadAuthState() else {
            return ProviderSnapshot.error(provider: provider, message: CursorAuthError.notLoggedIn.localizedDescription)
        }

        do {
            return try await probe(authState: state)
        } catch {
            return ProviderSnapshot.error(provider: provider, message: error.localizedDescription)
        }
    }

    private func probe(authState initialState: CursorAuthState) async throws -> ProviderSnapshot {
        var authState = initialState
        var accessToken = authState.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if authStore.needsRefresh(accessToken) {
            do {
                if let refreshed = try await refreshAccessToken(authState: authState) {
                    authState.accessToken = refreshed
                    accessToken = refreshed
                } else if accessToken == nil {
                    throw CursorAuthError.notLoggedIn
                }
            } catch {
                if accessToken == nil {
                    throw error
                }
            }
        }

        guard let accessToken else {
            throw CursorAuthError.notLoggedIn
        }

        let usageResponse = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        guard (200..<300).contains(usageResponse.statusCode) else {
            if usageResponse.statusCode == 401 || usageResponse.statusCode == 403 {
                throw CursorAuthError.tokenExpired
            }
            throw CursorUsageError.requestFailed(usageResponse.statusCode)
        }
        guard let usage = ProviderParse.jsonObject(usageResponse.body) else {
            throw CursorUsageError.invalidResponse
        }

        let (planName, planInfoUnavailable) = await fetchPlanName(accessToken: authState.accessToken ?? accessToken)
        let fallback = CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage,
            planName: planName,
            planInfoUnavailable: planInfoUnavailable
        )
        if fallback.0 {
            let mapped = try await requestBasedResult(
                accessToken: authState.accessToken ?? accessToken,
                planName: planName,
                unavailableMessage: fallback.1
            )
            return snapshot(mapped)
        }

        if shouldTryGenericRequestFallback(usage: usage) {
            if let mapped = try? await requestBasedResult(
                accessToken: authState.accessToken ?? accessToken,
                planName: planName,
                unavailableMessage: "Cursor request-based usage data unavailable. Try again later."
            ) {
                return snapshot(mapped)
            }
        }

        let creditGrants = await fetchCreditGrants(accessToken: authState.accessToken ?? accessToken)
        let stripeResponse = try? await usageClient.fetchStripeBalance(accessToken: authState.accessToken ?? accessToken)
        let stripeBalanceCents = CursorUsageMapper.stripeBalanceCents(from: stripeResponse ?? nil)
        var mapped = try CursorUsageMapper.mapUsage(
            usage: usage,
            planName: planName,
            creditGrants: creditGrants,
            stripeBalanceCents: stripeBalanceCents
        )
        await appendSpendLines(to: &mapped.lines, accessToken: authState.accessToken ?? accessToken)
        return snapshot(mapped)
    }

    /// Strictly additive: fetch the usage CSV and append the three per-day spend tiles. Any failure
    /// (no session, non-2xx, or undecodable body) appends nothing, so the live Cursor mapping is never
    /// affected and the spend tiles fall back to "No data".
    private func appendSpendLines(to lines: inout [MetricLine], accessToken: String) async {
        let calendar = Calendar.current
        let end = now()
        let startOfToday = calendar.startOfDay(for: end)
        let start = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday

        guard let response = try? await usageClient.fetchUsageCSV(accessToken: accessToken, start: start, end: end),
              (200..<300).contains(response.statusCode),
              let csv = String(data: response.body, encoding: .utf8)
        else {
            return
        }
        let rows = CursorUsageCSV.parse(csv: csv)
        CursorUsageMapper.appendSpendLines(rows: rows, now: end, to: &lines)
    }

    private func fetchUsageWithRetry(accessToken: String, authState: inout CursorAuthState) async throws -> HTTPResponse {
        var working = authState
        defer { authState = working }
        return try await ProviderAuthRetry.fetch(
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshed = try await self.refreshAccessToken(authState: working) else {
                    throw CursorAuthError.tokenExpired
                }
                working.accessToken = refreshed
                return refreshed
            },
            connectionFailed: CursorUsageError.connectionFailed,
            retriedConnectionFailed: CursorUsageError.usageAfterRefreshFailed,
            authExpired: CursorAuthError.tokenExpired
        )
    }

    private func refreshAccessToken(authState: CursorAuthState) async throws -> String? {
        guard let refreshToken = authState.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }

        let response = try await usageClient.refreshToken(refreshToken)
        if response.statusCode == 400 || response.statusCode == 401 {
            let body = ProviderParse.jsonObject(response.body)
            if body?["shouldLogout"] as? Bool == true {
                throw CursorAuthError.sessionExpired
            }
            throw CursorAuthError.tokenExpired
        }
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body)
        else {
            return nil
        }
        if body["shouldLogout"] as? Bool == true {
            throw CursorAuthError.sessionExpired
        }
        guard let accessToken = (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        try? authStore.saveAccessToken(accessToken, source: authState.source)
        return accessToken
    }

    private func fetchPlanName(accessToken: String) async -> (String?, Bool) {
        do {
            let response = try await usageClient.fetchPlan(accessToken: accessToken)
            guard (200..<300).contains(response.statusCode),
                  let body = ProviderParse.jsonObject(response.body),
                  let planInfo = body["planInfo"] as? [String: Any]
            else {
                return (nil, true)
            }
            return (planInfo["planName"] as? String, false)
        } catch {
            return (nil, true)
        }
    }

    private func fetchCreditGrants(accessToken: String) async -> [String: Any]? {
        guard let response = try? await usageClient.fetchCredits(accessToken: accessToken),
              (200..<300).contains(response.statusCode)
        else {
            return nil
        }
        return ProviderParse.jsonObject(response.body)
    }

    private func requestBasedResult(accessToken: String, planName: String?, unavailableMessage: String) async throws -> CursorMappedUsage {
        do {
            guard let response = try await usageClient.fetchRequestBasedUsage(accessToken: accessToken),
                  (200..<300).contains(response.statusCode),
                  let body = ProviderParse.jsonObject(response.body)
            else {
                throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
            }
            return try CursorUsageMapper.mapRequestBasedUsage(body, planName: planName, unavailableMessage: unavailableMessage)
        } catch let error as CursorUsageError {
            throw error
        } catch {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }
    }

    private func shouldTryGenericRequestFallback(usage: [String: Any]) -> Bool {
        guard usage["enabled"] as? Bool != false,
              let planUsage = usage["planUsage"] as? [String: Any],
              ProviderParse.number(planUsage["limit"]) == nil,
              ProviderParse.number(planUsage["totalPercentUsed"]) == nil
        else {
            return false
        }
        return true
    }

    private func snapshot(_ mapped: CursorMappedUsage) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: mapped.plan,
            lines: mapped.lines,
            refreshedAt: now()
        )
    }
}
