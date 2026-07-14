import Foundation

/// Typed failures for the OpenCode provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum OpenCodeUsageError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// `auth.json` exists but could not be read or parsed — broken storage, not logout. `detail`
    /// carries the underlying cause for the log file; the user-facing description stays friendly.
    case credentialsUnreadable(detail: String)
    /// OpenCode databases exist on disk but none could be read this refresh. Failing loudly here beats
    /// rendering authoritative-looking $0 meters from an empty scan.
    case databaseUnreadable

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "OpenCode not detected. Log in with a provider in OpenCode or use OpenCode locally first."
        case .credentialsUnreadable:
            return "Couldn't read OpenCode's auth.json. Check its file permissions or log into OpenCode again."
        case .databaseUnreadable:
            return "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions."
        }
    }
}

/// Tracks every model used through OpenCode from its local SQLite logs. Cookie-free and network-free —
/// see `OpenCodeUsageScanner`. The card shows Go-only plan caps plus all-provider token/spend tiles and
/// a usage trend; zero-cost external rows are priced through the shared catalog when possible.
@MainActor
final class OpenCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "opencode",
        displayName: "OpenCode",
        icon: .providerMark("opencode"),
        links: [
            .init(label: "Dashboard", url: "https://opencode.ai/auth")
        ]
    )

    let authStore: OpenCodeAuthStore
    let usageScanner: OpenCodeUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    /// OpenCode derives per-message costs from model metadata; they are API-rate values, not charges.
    private let sourceNote = "From your OpenCode logs (API-rate estimate)"

    /// Edge-triggers the auth-read-failure log so a persistently unreadable `auth.json` warns once per
    /// run, not once per 5-minute refresh.
    private var loggedAuthReadFailure = false

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageScanner: OpenCodeUsageScanner = OpenCodeUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageScanner = usageScanner
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        // Go plan caps read from local `opencode-go` spend (Session/Weekly above the fold, Monthly on
        // demand); the spend tiles + trend below sum every provider used through OpenCode.
        [
            .boundedDollars(id: "opencode.session", provider: provider, title: "Session", limit: OpenCodeUsageMapper.sessionCap)
                .exportingLimit("session", unit: "usd", estimated: true),
            .boundedDollars(id: "opencode.weekly", provider: provider, title: "Weekly", limit: OpenCodeUsageMapper.weeklyCap)
                .exportingLimit("weekly", unit: "usd", estimated: true),
            .boundedDollars(id: "opencode.monthly", provider: provider, title: "Monthly", limit: OpenCodeUsageMapper.monthlyCap)
                .exportingLimit("monthly", unit: "usd", estimated: true),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: any provider login or any usage already in the local database.
        // Local-only, off the main actor. An unreadable auth.json is itself an
        // OpenCode footprint — enable the provider so `refresh()` can surface the actionable error.
        await loadOffMainActor { [authStore, usageScanner] in
            do {
                let auth = try authStore.loadState()
                if auth.hasAnyProviderLogin || auth.goAPIKey != nil { return true }
            } catch {
                return true
            }
            return usageScanner.hasUsage()
        }
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()

        // An unreadable auth.json must not kill a refresh that can still read the database (a Zen user
        // stays live), but it stays distinguishable from "not logged in" when nothing else loads.
        var authState = OpenCodeAuthState(hasAnyProviderLogin: false, goAPIKey: nil)
        var authReadError: OpenCodeUsageError?
        do {
            authState = try await loadOffMainActor { [authStore] in try authStore.loadState() }
            loggedAuthReadFailure = false
        } catch let error as OpenCodeUsageError {
            authReadError = error
            if case .credentialsUnreadable(let detail) = error, !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("opencode"), "auth.json unreadable: \(detail)")
            }
        } catch {
            authReadError = .credentialsUnreadable(detail: error.localizedDescription)
        }

        let scan: OpenCodeUsageScan?
        do {
            scan = try await usageScanner.scan(
                now: refreshedAt,
                hasGoKey: authState.goAPIKey != nil,
                pricing: pricing
            )
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }

        guard let scan else {
            // No OpenCode database on disk at all.
            if authState.goAPIKey != nil {
                // Freshly logged into Go, before the first local message: the key alone establishes the
                // plan, so show the published caps at $0 rather than a bare "No usage data".
                let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: nil, now: refreshedAt)
                return ProviderSnapshot.make(
                    provider: provider, plan: "Go",
                    lines: OpenCodeUsageMapper.meterLines(windows), refreshedAt: refreshedAt
                )
            }
            if authState.hasAnyProviderLogin {
                var lines: [MetricLine] = []
                MetricLine.appendNoDataIfNeeded(&lines)
                return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: refreshedAt)
            }
            return ProviderSnapshot.error(
                provider: provider, error: authReadError ?? OpenCodeUsageError.notLoggedIn
            )
        }

        var lines: [MetricLine] = []
        if let windows = scan.goWindows {
            lines.append(contentsOf: OpenCodeUsageMapper.meterLines(windows))
        }
        SpendTileMapper.appendTokenUsage(
            scan.logScan.series, to: &lines, now: refreshedAt,
            estimated: true,
            unknownModelsByDay: scan.logScan.unknownModelsByDay,
            modelUsage: scan.logScan.modelUsage,
            modelSourceNote: sourceNote
        )
        SpendTileMapper.appendUsageTrend(scan.logScan.series, to: &lines, now: refreshedAt, note: sourceNote)
        MetricLine.appendNoDataIfNeeded(&lines)

        // `goWindows` is present only on a current Go signal (key or recent spend), never a stale anchor,
        // so it's the honest source for the plan badge too.
        let plan: String? = scan.goWindows != nil ? "Go" : nil
        return ProviderSnapshot.make(
            provider: provider,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: ProviderUsageHistory(
                series: scan.logScan.series,
                modelUsage: scan.logScan.modelUsage,
                unknownModelsByDay: scan.logScan.unknownModelsByDay
            ),
            warning: scan.warning
        )
    }
}
