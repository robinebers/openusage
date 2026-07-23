import Foundation

@MainActor
final class OllamaProvider: ProviderRuntime {
    let provider = Provider(
        id: "ollama",
        displayName: "Ollama",
        icon: .providerMark("ollama"),
        links: [
            ProviderLink(label: "Settings", url: "https://ollama.com/settings"),
            ProviderLink(label: "Keys", url: "https://ollama.com/settings/keys")
        ]
    )

    let authStore: OllamaAuthStore
    let usageClient: OllamaUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: OllamaAuthStore = OllamaAuthStore(),
        usageClient: OllamaUsageClient = OllamaUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "ollama.session", provider: provider, title: "Session", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "ollama.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in authStore.loadSessionCookie() } != nil
            || await loadOffMainActor { [authStore] in authStore.loadAPIKey() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        if let cookie = await loadOffMainActor({ [authStore] in authStore.loadSessionCookie() }) {
            return await refreshWithCookie(cookie)
        }

        if let apiKey = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) {
            return await refreshWithAPIKey(apiKey)
        }

        return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.missingSession)
    }

    private func refreshWithCookie(_ cookie: OllamaSessionCookie) async -> ProviderSnapshot {
        do {
            let response = try await usageClient.fetchSettings(cookie: cookie.value)
            let status = response.statusCode
            if status == 302 || status == 303 || status == 307 || status == 308 {
                return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.sessionExpired)
            }
            if status == 401 || status == 403 {
                return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.sessionExpired)
            }
            guard (200..<300).contains(status) else {
                return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.requestFailed(status))
            }
            guard let html = String(data: response.body, encoding: .utf8),
                  let data = OllamaUsageMapper.parseSettingsHTML(html, now: now()) else {
                return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.parseFailed)
            }
            let lines = OllamaUsageMapper.buildLines(from: data)
            return ProviderSnapshot.make(provider: provider, plan: data.plan, lines: lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.connectionFailed)
        }
    }

    private func refreshWithAPIKey(_ apiKey: String) async -> ProviderSnapshot {
        do {
            let response = try await usageClient.fetchAccountUsage(apiKey: apiKey)
            if response.statusCode == 401 || response.statusCode == 403 {
                return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.invalidAPIKey)
            }
            guard (200..<300).contains(response.statusCode) else {
                return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.requestFailed(response.statusCode))
            }
            guard let data = OllamaUsageMapper.parseAPIUsage(response.body) else {
                return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.parseFailed)
            }
            let lines = OllamaUsageMapper.buildLines(from: data)
            return ProviderSnapshot.make(provider: provider, plan: data.plan, lines: lines, refreshedAt: now())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: OllamaUsageError.connectionFailed)
        }
    }
}
