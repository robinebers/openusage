import Foundation

@MainActor
final class DevinProvider: ProviderRuntime {
    let provider = Provider(
        id: "devin",
        displayName: "Devin",
        icon: .providerMark("devin"),
        links: [
            .init(label: "Dashboard", url: "https://app.devin.ai/settings/plans")
        ]
    )

    let authStore: DevinAuthStore
    let usageClient: DevinUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: DevinAuthStore = DevinAuthStore(),
        usageClient: DevinUsageClient = DevinUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "devin.daily", provider: provider, title: "Daily", metricLabel: "Daily quota"),
            .percent(id: "devin.weekly", provider: provider, title: "Weekly", metricLabel: "Weekly quota"),
            .dollarBalance(id: "devin.extra", provider: provider, title: "Extra Balance", metricLabel: "Extra usage balance", valueWord: "left")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: the credentials file, then the Devin app's stored auth. Both are
        // blocking disk/SQLite reads, so both run off the main actor (see `loadOffMainActor`).
        if await loadOffMainActor({ [authStore] in authStore.loadCredentialsFile() }) != nil { return true }
        return await loadOffMainActor { [authStore] in authStore.loadAppAuth() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        var sawAuthFailure = false
        var firstUsageFailure: DevinUsageError?
        let credentials = await loadOffMainActor { [authStore] in authStore.loadCredentialsFile() }

        if let credentials {
            switch await attempt(auth: credentials, sourceLabel: "CLI credentials") {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .usageFailure(let error):
                firstUsageFailure = error
            }
        }

        let appAuth = await loadOffMainActor({ [authStore] in authStore.loadAppAuth() })
        if let appAuth,
           credentials == nil || shouldAttemptAppAuth(appAuth, after: credentials) {
            switch await attempt(auth: appAuth, sourceLabel: "app credentials") {
            case .success(let mapped):
                return snapshot(from: mapped)
            case .authFailure:
                sawAuthFailure = true
            case .usageFailure(let error):
                firstUsageFailure = firstUsageFailure ?? error
            }
        }

        // An auth rejection only proves that one candidate is stale. If another candidate encountered a
        // transport, HTTP, or decoding failure, preserve that actionable failure instead of replacing it
        // with a misleading login fallback.
        if let firstUsageFailure {
            return ProviderSnapshot.error(provider: provider, error: firstUsageFailure)
        }
        if sawAuthFailure {
            return ProviderSnapshot.error(provider: provider, error: DevinAuthError.sessionExpired)
        }
        return ProviderSnapshot.error(provider: provider, error: DevinAuthError.notLoggedIn)
    }

    private func attempt(auth: DevinAuth, sourceLabel: String) async -> DevinAuthAttempt {
        let apiServerURL = authStore.effectiveAPIServerURL(auth)
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchUserStatus(auth: auth, apiServerURL: apiServerURL)
        } catch let error as DevinUsageError {
            AppLog.error(LogTag.plugin("devin"), "\(sourceLabel) quota request could not be created")
            return .usageFailure(error)
        } catch {
            AppLog.error(LogTag.plugin("devin"), "\(sourceLabel) quota request failed to connect")
            return .usageFailure(.connectionFailed)
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            AppLog.warn(LogTag.auth("devin"), "\(sourceLabel) rejected (HTTP \(response.statusCode)); trying the next source if available")
            return .authFailure
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.error(LogTag.plugin("devin"), "\(sourceLabel) quota request failed (HTTP \(response.statusCode))")
            return .usageFailure(.requestFailed(response.statusCode))
        }

        do {
            return .success(try DevinUsageMapper.mapUserStatusResponse(response))
        } catch let error as DevinUsageError {
            AppLog.error(LogTag.plugin("devin"), "\(sourceLabel) quota response was unusable")
            return .usageFailure(error)
        } catch {
            AppLog.error(LogTag.plugin("devin"), "\(sourceLabel) quota response could not be decoded")
            return .usageFailure(.invalidResponse)
        }
    }

    private func shouldAttemptAppAuth(_ appAuth: DevinAuth, after credentials: DevinAuth?) -> Bool {
        guard let credentials else { return true }
        return appAuth.apiKey != credentials.apiKey ||
            authStore.effectiveAPIServerURL(appAuth) != authStore.effectiveAPIServerURL(credentials)
    }

    private func snapshot(from mapped: DevinMappedUsage) -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now())
    }
}

private enum DevinAuthAttempt {
    case success(DevinMappedUsage)
    case authFailure
    case usageFailure(DevinUsageError)
}
