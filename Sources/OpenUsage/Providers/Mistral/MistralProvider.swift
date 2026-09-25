import Foundation

@MainActor
final class MistralProvider: ProviderRuntime {
    let provider = Provider(
        id: "mistral",
        displayName: "Mistral",
        icon: .providerMark("mistral"),
        links: [
            ProviderLink(label: "Usage", url: "https://admin.mistral.ai/organization/usage"),
            ProviderLink(label: "Subscription", url: "https://admin.mistral.ai/subscription")
        ]
    )

    let authStore: MistralAuthStore
    let usageClient: MistralUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: MistralAuthStore = MistralAuthStore(),
        usageClient: MistralUsageClient = MistralUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "mistral.api", provider: provider, title: "API",
                     metricLabel: "API")
                .exportingLimit("api", unit: "percent"),
            .percent(id: "mistral.vibe", provider: provider, title: "Vibe",
                     metricLabel: "Vibe")
                .exportingLimit("vibe", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Mirror `refresh()`: any usable saved header or browser session counts as a local login.
        await loadOffMainActor { [authStore] in (try? authStore.loadAuth()) != nil }
    }

    func refresh() async -> ProviderSnapshot {
        let auth: MistralAuth?
        do {
            auth = try await loadOffMainActor { [authStore] in try authStore.loadAuth() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: MistralAuthError.cookiesUnreadable)
        }
        guard let auth else {
            return ProviderSnapshot.error(provider: provider, error: MistralAuthError.notSignedIn)
        }
        // The subscription page carries both allowances (API + Vibe); the console tRPC route is a
        // best-effort Vibe fallback when the page reports none. Both are optional in the same sense:
        // an account without allowances reads "No usage data" instead of erroring — but an expired
        // session must surface as a clear error, not as an empty card.
        var subscriptionHTML: String?
        var sessionExpired = false
        do {
            let response = try await usageClient.fetchSubscriptionPage(auth: auth)
            switch response.statusCode {
            case 200:
                subscriptionHTML = String(decoding: response.body, as: UTF8.self)
            case 301, 302, 303, 307, 308, 401, 403:
                sessionExpired = true
            default:
                AppLog.warn(LogTag.plugin("mistral"), "subscription page fetch failed (HTTP \(response.statusCode))")
            }
        } catch {
            AppLog.warn(LogTag.plugin("mistral"), "subscription page fetch failed (network)")
        }
        var vibeBody: Data?
        if !sessionExpired {
            do {
                let response = try await usageClient.fetchVibeUsage(auth: auth)
                if (200..<300).contains(response.statusCode) {
                    vibeBody = response.body
                } else if response.statusCode == 401 || response.statusCode == 403 {
                    sessionExpired = true
                }
            } catch {
                // Best-effort: no Vibe fallback data this refresh.
            }
        }
        if sessionExpired {
            return ProviderSnapshot.error(provider: provider, error: MistralUsageError.sessionExpired)
        }
        let lines = MistralUsageMapper.map(subscriptionHTML: subscriptionHTML, vibeBody: vibeBody)
        return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
    }
}
