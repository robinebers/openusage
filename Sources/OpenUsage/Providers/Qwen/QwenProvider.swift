import Foundation

/// Qwen Cloud Token Plan (individual edition) usage: a rolling 5-hour quota window and a rolling
/// weekly window, both read from the home.qwencloud.com console API the billing page itself uses.
/// The API is cookies-only (Qwen API keys are inference-only), so credentials are a browser session
/// captured by the in-app sign-in window or pasted into `~/.config/openusage/qwen.json`.
@MainActor
final class QwenProvider: ProviderRuntime {
    let provider = Provider(
        id: "qwen",
        displayName: "Qwen",
        icon: .providerMark("qwen"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://home.qwencloud.com/billing/subscription/token-plan-individual")
        ]
    )

    let authStore: QwenAuthStore
    let usageClient: QwenUsageClient
    /// Owns the one-at-a-time sign-in window. The provider is long-lived, so the controller (and
    /// its pinned active window) survives Customize detail appearances.
    let loginController: QwenLoginController
    let now: @Sendable () -> Date

    init(
        authStore: QwenAuthStore = QwenAuthStore(),
        usageClient: QwenUsageClient = QwenUsageClient(),
        loginController: QwenLoginController? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.loginController = loginController ?? QwenLoginController(authStore: authStore, usageClient: usageClient)
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "qwen.session", provider: provider, title: "Session",
                     metricLabel: "5-Hour", isSessionWindow: true)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "qwen.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`: a captured session file.
        await loadOffMainActor { [authStore] in authStore.loadSession() } != nil
    }

    func refresh() async -> ProviderSnapshot {
        guard let session = await loadOffMainActor({ [authStore] in authStore.loadSession() }) else {
            return ProviderSnapshot.error(provider: provider, error: QwenAuthError.notSignedIn)
        }

        // The info call is both the sec_token source and the session-liveness probe: dead cookies
        // surface here as `.sessionExpired` before the billing calls are even attempted.
        switch await load({ try await usageClient.fetchInfo(cookies: session.cookies) }) {
        case .authFailure:
            return ProviderSnapshot.error(provider: provider, error: QwenUsageError.sessionExpired)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        case .success(let infoBody):
            guard let secToken = QwenUsageMapper.secToken(from: infoBody) else {
                let error: QwenUsageError = QwenUsageMapper.isConsoleLoginFailure(infoBody)
                    ? .sessionExpired
                    : .invalidResponse
                return ProviderSnapshot.error(provider: provider, error: error)
            }
            return await refreshUsage(session: session, secToken: secToken)
        }
    }

    /// The required usage call plus the best-effort subscription/quota-config decoration (plan
    /// label + renewal warning). Failures in the optional calls never blank the meters.
    private func refreshUsage(session: QwenSession, secToken: String) async -> ProviderSnapshot {
        let usage = await load { [usageClient] in
            try await usageClient.fetch(.usage, cookies: session.cookies, secToken: secToken, region: session.region)
        }
        switch usage {
        case .authFailure:
            return ProviderSnapshot.error(provider: provider, error: QwenUsageError.sessionExpired)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        case .success(let body):
            do {
                let lines = try QwenUsageMapper.mapUsage(body)
                let subscriptionBody = await loadOptional { [usageClient] in
                    try await usageClient.fetch(.subscription, cookies: session.cookies, secToken: secToken, region: session.region)
                }
                var plan: String?
                var warning: String?
                if let subscriptionBody, let info = try? QwenUsageMapper.mapSubscription(subscriptionBody) {
                    warning = info.renewalWarning
                    let capsBody = await loadOptional { [usageClient] in
                        try await usageClient.fetch(.quotaConfig, cookies: session.cookies, secToken: secToken, region: session.region)
                    }
                    let caps = capsBody.flatMap { QwenUsageMapper.quotaCaps($0, tierKey: info.tierKey) }
                    plan = QwenUsageMapper.planLabel(planName: info.planName, caps: caps)
                }
                return ProviderSnapshot.make(provider: provider, plan: plan, lines: lines,
                                             refreshedAt: now(), warning: warning)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }
    }

    /// Run a required call and classify the outcome: the body on 2xx, an auth failure on 401/403,
    /// or a typed failure for any other non-2xx or transport error.
    private func load(_ call: () async throws -> HTTPResponse) async -> CallResult {
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

    /// Run an optional call — never throws into the snapshot: any failure just means "no plan
    /// decoration this refresh".
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

private enum CallResult {
    case success(Data)
    case authFailure
    case failed(QwenUsageError)
}

extension QwenProvider: SessionManaging {
    var hasSession: Bool { authStore.loadSession() != nil }

    func beginSignIn(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        loginController.beginSignIn { result in
            completion(result.map { _ in () })
        }
    }

    func signOut() throws {
        try authStore.deleteSession()
    }
}
