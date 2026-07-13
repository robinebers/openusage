import Foundation

@MainActor
final class CopilotProvider: ProviderRuntime {
    /// `UserDefaults` key caching the slug of the org whose billing carried Copilot credit usage, so
    /// steady-state refreshes make one billing call instead of re-probing every org.
    static let billingOrgDefaultsKey = "copilot.billingOrg"

    let provider = Provider(
        id: "copilot",
        displayName: "Copilot",
        icon: .providerMark("copilot"),
        links: [
            .init(label: "Status", url: "https://www.githubstatus.com/"),
            .init(label: "Dashboard", url: "https://github.com/settings/billing")
        ]
    )

    let authStore: CopilotAuthStore
    let usageClient: CopilotUsageClient
    let orgBillingClient: CopilotOrgBillingClient
    let defaults: UserDefaults
    let now: @Sendable () -> Date

    init(
        authStore: CopilotAuthStore = CopilotAuthStore(),
        usageClient: CopilotUsageClient = CopilotUsageClient(),
        orgBillingClient: CopilotOrgBillingClient = CopilotOrgBillingClient(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.orgBillingClient = orgBillingClient
        self.defaults = defaults
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "copilot.premium", provider: provider, title: "Credits")
                .exportingLimit("premiumCredits", unit: "percent"),
            .values(id: "copilot.extra", provider: provider, title: "Extra Usage", selection: .kind(.count))
                .exportingLimit("extraUsage", unit: "count", source: .value(kind: .count)),
            .values(id: "copilot.orgCredits", provider: provider, title: "Org Credits", selection: .kind(.count))
                .exportingLimit("orgCredits", unit: "credits", source: .value(kind: .count, label: "credits")),
            .values(id: "copilot.orgSpend", provider: provider, title: "Org Spend", selection: .kind(.dollars), valueWord: "spent")
                .exportingLimit("orgSpend", unit: "usd", source: .value(kind: .dollars)),
            .percent(id: "copilot.chat", provider: provider, title: "Chat")
                .exportingLimit("chat", unit: "percent"),
            .percent(id: "copilot.completions", provider: provider, title: "Completions")
                .exportingLimit("completions", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: editor config, gh config, or the gh keychain entry.
        await loadOffMainActor { [authStore] in authStore.loadToken() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        let token = await loadOffMainActor { [authStore] in authStore.loadToken() }
        guard let token else {
            return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.notLoggedIn)
        }

        do {
            let response = try await usageClient.fetchUsage(token: token.value)

            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: CopilotAuthError.tokenInvalid)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.requestFailed(response.statusCode))
            }

            let mapped = try CopilotUsageMapper.map(response)

            // An org-managed (token-based-billing) seat has no per-seat quota, so the real usage lives
            // in the org's billing. Look it up there — best-effort: an org admin sees Org Credits /
            // Org Spend, everyone else keeps the plan-only card as before. Gated on the mapper's
            // explicit flag, never on `lines` being empty (issue #839).
            var lines = mapped.lines
            if mapped.isOrgManagedSeat {
                lines = await orgBillingLines(token: token.value)
            }

            return ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: lines, refreshedAt: now())
        } catch let error as CopilotUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: CopilotUsageError.connectionFailed)
        }
    }

    // MARK: - Org billing lookup

    /// Org-level Copilot billing lines for an org-managed seat. Tries the cached org first, then probes
    /// every org the user belongs to, remembering the first whose billing summary carries Copilot credit
    /// usage. Returns `[]` when nothing is readable — a 403 is the *expected* outcome for a plain org
    /// member (only owners and billing managers can read org billing), so it degrades to today's
    /// plan-only card instead of erroring the provider.
    private func orgBillingLines(token: String) async -> [MetricLine] {
        if let cached = defaults.string(forKey: Self.billingOrgDefaultsKey) {
            do {
                if let lines = try await usageLines(org: cached, token: token) {
                    return lines
                }
                // The cached org answered but no longer shows Copilot usage (left the org, lost the
                // billing role, org stopped using Copilot) — forget it and re-probe from scratch.
                defaults.removeObject(forKey: Self.billingOrgDefaultsKey)
            } catch {
                // Transient failure: log it and keep the cached org for the next refresh.
                AppLog.warn(LogTag.plugin("copilot"), "org billing lookup failed for the remembered org: \(error.localizedDescription)")
                return []
            }
        }

        let orgs: [String]
        do {
            let response = try await orgBillingClient.fetchUserOrgs(token: token)
            guard response.statusCode == 200 else {
                // 403 here means the token lacks `read:org` (editor-plugin tokens can) — expected, not
                // an error. Anything else is still worth a diagnostic, never a failed card.
                AppLog.info(LogTag.plugin("copilot"), "org list HTTP \(response.statusCode); skipping org billing lookup")
                return []
            }
            orgs = CopilotOrgBillingMapper.orgLogins(response)
        } catch {
            AppLog.warn(LogTag.plugin("copilot"), "org list fetch failed: \(error.localizedDescription)")
            return []
        }

        for org in orgs {
            do {
                if let lines = try await usageLines(org: org, token: token) {
                    defaults.set(org, forKey: Self.billingOrgDefaultsKey)
                    return lines
                }
            } catch {
                // One org's billing having an outage must not hide another org's usage — keep probing.
                AppLog.warn(LogTag.plugin("copilot"), "org billing summary failed for one org; trying the next: \(error.localizedDescription)")
            }
        }
        return []
    }

    /// One org's billing summary → metric lines, or `nil` when this org definitively has nothing to show
    /// (no access — the expected 403 for plain members — or no Copilot credit usage in the summary).
    /// Throws for transient failures (transport errors, 429, 5xx) so callers keep the cached org instead
    /// of treating a brief outage as a stale org.
    private func usageLines(org: String, token: String) async throws -> [MetricLine]? {
        let response = try await orgBillingClient.fetchUsageSummary(org: org, token: token)
        guard response.statusCode == 200 else {
            AppLog.debug(LogTag.plugin("copilot"), "org billing summary for one org: HTTP \(response.statusCode)")
            if response.statusCode == 429 || response.statusCode >= 500 {
                throw CopilotUsageError.requestFailed(response.statusCode)
            }
            return nil
        }
        return CopilotOrgBillingMapper.usageLines(response)
    }
}
