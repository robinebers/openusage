import Foundation

@MainActor
final class CommandCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "commandcode",
        displayName: "Command Code",
        icon: .providerMark("commandcode"),
        links: [
            ProviderLink(label: "Usage", url: "https://commandcode.ai/usage"),
            ProviderLink(label: "Dashboard", url: "https://commandcode.ai/studio")
        ]
    )

    let authStore: CommandCodeAuthStore
    let usageClient: CommandCodeUsageClient
    let now: @Sendable () -> Date

    init(
        authStore: CommandCodeAuthStore = CommandCodeAuthStore(),
        usageClient: CommandCodeUsageClient = CommandCodeUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .boundedDollars(
                id: "commandcode.fiveHour",
                provider: provider,
                title: "5-Hour",
                limit: 3,
                menuBarShowsPercentage: true,
                isSessionWindow: true
            )
            .exportingLimit("fiveHour", unit: "usd"),
            .boundedDollars(
                id: "commandcode.weekly",
                provider: provider,
                title: "Weekly",
                limit: 6,
                menuBarShowsPercentage: true
            )
            .exportingLimit("weekly", unit: "usd"),
            .boundedDollars(
                id: "commandcode.monthly",
                provider: provider,
                title: "Monthly",
                limit: 10,
                menuBarShowsPercentage: true
            )
            .exportingLimit("monthly", unit: "usd"),
            .dollarBalance(
                id: "commandcode.balance",
                provider: provider,
                title: "Balance",
                valueWord: "left"
            )
            .exportingLimit(
                "balance",
                kind: .balance,
                unit: "usd",
                source: .value(kind: .dollars)
            ),
            .values(
                id: "commandcode.requests",
                provider: provider,
                title: "Requests",
                selection: .kind(.count),
                isUsagePeriod: true
            )
            .exportingLimit("requests", unit: "requests", source: .value(kind: .count))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in
            (try? authStore.loadAuth()) != nil
        }
    }

    func refresh() async -> ProviderSnapshot {
        let auth: CommandCodeAuth
        do {
            guard let loaded = try await loadOffMainActor({ [authStore] in try authStore.loadAuth() }) else {
                return ProviderSnapshot.error(provider: provider, error: CommandCodeAuthError.notLoggedIn)
            }
            auth = loaded
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        do {
            let whoamiBody = try await load { try await usageClient.fetchWhoami(apiKey: auth.apiKey) }
            let organizationID = try CommandCodeUsageMapper.organizationID(from: whoamiBody)

            let creditsBody = try await load {
                try await usageClient.fetchCredits(apiKey: auth.apiKey, organizationID: organizationID)
            }
            let subscriptionBody = try await load {
                try await usageClient.fetchSubscription(apiKey: auth.apiKey, organizationID: organizationID)
            }
            let subscription = try CommandCodeUsageMapper.subscriptionContext(from: subscriptionBody)
            let summaryBody = try await load {
                try await usageClient.fetchUsageSummary(
                    apiKey: auth.apiKey,
                    organizationID: organizationID,
                    since: subscription?.currentPeriodStart
                )
            }
            let mapped = try CommandCodeUsageMapper.map(
                creditsBody: creditsBody,
                summaryBody: summaryBody,
                subscription: subscription
            )
            return ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: now()
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    private func load(_ request: () async throws -> HTTPResponse) async throws -> Data {
        do {
            let response = try await request()
            if response.statusCode == 401 {
                throw CommandCodeAuthError.sessionExpired
            }
            guard (200..<300).contains(response.statusCode) else {
                throw CommandCodeUsageError.requestFailed(response.statusCode)
            }
            guard !response.body.isEmpty else {
                throw CommandCodeUsageError.invalidResponse
            }
            return response.body
        } catch let error as CommandCodeAuthError {
            throw error
        } catch let error as CommandCodeUsageError {
            throw error
        } catch {
            throw CommandCodeUsageError.connectionFailed
        }
    }
}
