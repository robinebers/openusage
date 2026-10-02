import Foundation

@MainActor
final class ZAIProvider: ProviderRuntime {
    let provider = Provider(
        id: "zai",
        displayName: "Z.ai",
        icon: .providerMark("zai"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://z.ai/manage-apikey/coding-plan/personal/my-plan"),
            ProviderLink(label: "API Keys", url: "https://z.ai/manage-apikey/apikey-list")
        ]
    )

    let authStore: ZAIAuthStore
    let usageClient: ZAIUsageClient
    let usageScanner: ZcodeUsageScanner
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date
    private let sourceNote = "From your Zcode usage history (estimated)"

    init(
        usageScanner: ZcodeUsageScanner = ZcodeUsageScanner(),
        authStore: ZAIAuthStore = ZAIAuthStore(),
        usageClient: ZAIUsageClient = ZAIUsageClient(),
        pricing: @escaping @Sendable () async -> ModelPricing = { ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.usageScanner = usageScanner
        self.pricing = pricing
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        return [
            .percent(id: "zai.session", provider: provider, title: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "zai.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: sourceNote),
            .boundedCount(id: "zai.webSearches", provider: provider, title: "Web Searches",
                          limit: 1000, suffix: "searches", periodDurationMs: ZAIUsageMapper.monthlyPeriodMs)
                .exportingLimit("webSearches", unit: "searches"),
        ] + WidgetDescriptor.spendTiles(provider: provider, valueTooltipNote: sourceNote)
    }

    func hasLocalCredentials() async -> Bool {
        // Both sources used by refresh: quota credentials or local Zcode usage.
        await loadOffMainActor { [authStore, usageScanner] in
            authStore.loadAPIKey() != nil || usageScanner.hasModelUsage()
        }
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        let quota = await refreshQuota(at: refreshedAt)
        var scan: LogUsageScan?
        var scanError: Error?
        do {
            scan = try await usageScanner.scan(now: refreshedAt, pricing: await pricing())
        } catch {
            scanError = error
        }
        if scan == nil, quota.errorCategory != nil {
            if let error = scanError {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
            return quota
        }

        var lines = quota.errorCategory == nil
            ? quota.lines.filter { $0.label != MetricLine.noUsageData.label } : []
        var warnings: [String] = []
        if quota.errorCategory != nil, case .badge(_, let text, _, _)? = quota.lines.first {
            warnings.append(text)
        }
        if let error = scanError { warnings.append(error.localizedDescription) }
        if let scan {
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: refreshedAt, estimated: true,
                unknownModelsByDay: scan.unknownModelsByDay, modelUsage: scan.modelUsage,
                modelSourceNote: sourceNote, fallbackPricingModelsByDay: scan.fallbackPricingModelsByDay
            )
        }
        if let scan {
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: sourceNote)
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        if let warning { AppLog.warn(LogTag.plugin("zai"), "partial usage: \(warning)") }
        return ProviderSnapshot.make(
            provider: provider, plan: quota.plan, lines: lines, refreshedAt: refreshedAt,
            usageHistory: scan.map {
                ProviderUsageHistory(series: $0.series, modelUsage: $0.modelUsage,
                                     unknownModelsByDay: $0.unknownModelsByDay)
            },
            warning: warning
        )
    }

    private func refreshQuota(at refreshedAt: Date) async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) else {
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.missingKey)
        }

        // The quota endpoint is required; the subscription endpoint is best-effort (plan name only),
        // so a failure there must not blank out the meters. Both are fetched, and whatever the quota
        // returns is mapped alongside the plan name if the subscription succeeded.
        let quota = await load { try await usageClient.fetchQuota(apiKey: auth.apiKey) }
        let subscription = await loadOptional { try await usageClient.fetchSubscription(apiKey: auth.apiKey) }

        switch quota {
        case .success(let body):
            // A valid key whose account has no GLM Coding Plan gets a 2xx with `success:false`. Surface
            // that as a clear provider warning (the header's amber notice) rather than three blank "No
            // data" meters that don't explain why nothing's there.
            if ZAIUsageMapper.isNoCodingPlan(body) {
                return ProviderSnapshot.error(provider: provider, error: ZAIUsageError.noCodingPlan)
            }
            do {
                let mapped = try ZAIUsageMapper.map(quotaBody: body, subscriptionBody: subscription)
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: refreshedAt)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            return ProviderSnapshot.error(provider: provider, error: ZAIAuthError.invalidKey)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// Run the required quota call and classify the outcome: the body on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx, transport error, or empty body.
    private func load(_ call: () async throws -> HTTPResponse) async -> QuotaResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }

    /// Run the optional subscription call — never throws into the snapshot: a transport error, a
    /// non-2xx, or an auth failure all just mean "no plan name this refresh". Returns just the body
    /// (the only thing the mapper consumes); the outcome is otherwise discarded.
    private func loadOptional(_ call: () async throws -> HTTPResponse) async -> Data? {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else { return nil }
            return response.body
        } catch {
            return nil
        }
    }
}

extension ZAIProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}

private enum QuotaResult {
    case success(Data)
    case authFailure
    case failed(ZAIUsageError)
}
