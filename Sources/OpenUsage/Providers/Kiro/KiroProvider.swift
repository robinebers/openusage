import Foundation

@MainActor
final class KiroProvider: ProviderRuntime {
    let provider = Provider(
        id: "kiro",
        displayName: "Kiro",
        icon: .providerMark("kiro"),
        links: [
            .init(label: "Dashboard", url: "https://app.kiro.dev/account/usage")
        ]
    )

    let authStore: KiroAuthStore
    let usageClient: KiroUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: KiroAuthStore = KiroAuthStore(),
        usageClient: KiroUsageClient = KiroUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedCount(
                id: "kiro.credits",
                provider: provider,
                title: "Credits",
                metricLabel: "Credits used",
                limit: 50,
                suffix: "credits",
                periodDurationMs: KiroUsageMapper.billingPeriodMs
            )
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadAuth() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAuth() }) else {
            return ProviderSnapshot.error(provider: provider, error: KiroAuthError.notLoggedIn)
        }

        do {
            let response = try await usageClient.fetchUsageLimits(auth: auth)

            // 401/403 → not logged in / token expired
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: KiroAuthError.tokenExpired)
            }

            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: KiroUsageError.usageUnavailable)
            }

            let mapped = try KiroUsageMapper.mapUsageLimitsResponse(response)
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now()
            )
        } catch let error as KiroAuthError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch let error as KiroUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: KiroUsageError.connectionFailed)
        }
    }
}
