import Foundation

@MainActor
final class QoderProvider: ProviderRuntime {
    let provider = Provider(
        id: "qoder",
        displayName: "Qoder",
        icon: .providerMark("qoder"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://qoder.com/account/usage")
        ]
    )

    let authStore: QoderAuthStore
    let usageClient: QoderUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: QoderAuthStore = QoderAuthStore(),
        usageClient: QoderUsageClient = QoderUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "qoder.planCredits", provider: provider, title: QoderMetric.monthly),
            .boundedCount(id: "qoder.addOnCredits", provider: provider, title: QoderMetric.addOnCredits,
                          limit: 100, suffix: "credits"),
            .boundedCount(id: "qoder.orgCredits", provider: provider, title: QoderMetric.orgCredits,
                          limit: 100, suffix: "credits")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        if case .authenticated = await loadOffMainActor({ [authStore] in authStore.loadAuth() }) {
            return true
        }
        return false
    }

    func refresh() async -> ProviderSnapshot {
        let loaded = await loadOffMainActor { [authStore] in authStore.loadAuth() }
        let auth: QoderAuth
        switch loaded {
        case .authenticated(let found):
            auth = found
        case .missingCLI:
            return ProviderSnapshot.error(provider: provider, error: QoderAuthError.missingCLI)
        case .notLoggedIn:
            return ProviderSnapshot.error(provider: provider, error: QoderAuthError.notLoggedIn)
        case .statusUnavailable:
            return ProviderSnapshot.error(provider: provider, error: QoderAuthError.statusUnavailable)
        }

        let result = await loadUsage(auth)
        switch result {
        case .success(let usage):
            return ProviderSnapshot.make(
                provider: provider,
                plan: nil,
                lines: QoderUsageMapper.map(usage),
                refreshedAt: now()
            )
        case .failure(let error):
            AppLog.warn(LogTag.plugin("qoder"), "usage refresh failed: \(error.localizedDescription)")
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func loadUsage(_ auth: QoderAuth) async -> Result<QoderUsageInfo, QoderUsageError> {
        await Task.detached(priority: .utility) { [usageClient] in
            do {
                return .success(try usageClient.fetchUsage(auth: auth))
            } catch let error as QoderUsageError {
                return .failure(error)
            } catch {
                return .failure(.connectionFailed)
            }
        }.value
    }
}
