import Foundation

/// Typed failures for the OpenCode provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum OpenCodeUsageError: Error, LocalizedError, Equatable {
    case notLoggedIn
    /// `auth.json` exists but could not be read or parsed — broken storage, not logout. `detail`
    /// carries the underlying cause for the log file; the user-facing description stays friendly.
    case credentialsUnreadable(detail: String)
    /// OpenCode databases exist on disk but none could be read this refresh. Failing loudly here beats
    /// rendering authoritative-looking $0 tiles from an empty scan.
    case databaseUnreadable
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// The local Go key was rejected (HTTP 401 / `AuthError`).
    case unauthorized
    /// Valid key, but this account has no Go subscription (HTTP 403 / `EntitlementError`).
    case noGoSubscription

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first."
        case .credentialsUnreadable:
            return "Couldn't read OpenCode's auth.json. Check its file permissions or log into OpenCode Go again."
        case .databaseUnreadable:
            return "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions."
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .unauthorized:
            return "OpenCode Go key was rejected. Log into OpenCode Go again."
        case .noGoSubscription:
            return "No OpenCode Go subscription on this key."
        }
    }
}

/// Tracks OpenCode-hosted usage: Go plan windows from the official usage API, plus local spend tiles
/// and a usage trend from OpenCode's SQLite logs (Go + Zen).
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
    let usageClient: OpenCodeUsageClient
    let usageScanner: OpenCodeUsageScanner
    let now: @Sendable () -> Date

    /// Names the local source on hover (the dollars can only undercount true account usage — this
    /// machine only). No "(estimated)": OpenCode records its own per-message cost, so the values are
    /// measured, not imputed.
    private let sourceNote = "From your OpenCode logs"

    /// Edge-triggers the auth-read-failure log so a persistently unreadable `auth.json` warns once per
    /// run, not once per 5-minute refresh.
    private var loggedAuthReadFailure = false

    init(
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageClient: OpenCodeUsageClient = OpenCodeUsageClient(),
        usageScanner: OpenCodeUsageScanner = OpenCodeUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.usageScanner = usageScanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        // Go plan windows from `/zen/go/v1/usage` (Session/Weekly/Monthly + trend above the fold);
        // the spend tiles below sum combined OpenCode-hosted (Go + Zen) spend from local logs.
        [
            .percent(id: "opencode.session", provider: provider, title: "Session", sessionStartSignal: .zeroUsage)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "opencode.weekly", provider: provider, title: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "opencode.monthly", provider: provider, title: "Monthly")
                .exportingLimit("monthly", unit: "percent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: false,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: the local `opencode-go` auth key, or any hosted usage already in
        // the local database. Local-only, off the main actor. An unreadable auth.json is itself an
        // OpenCode footprint — enable the provider so `refresh()` can surface the actionable error.
        await loadOffMainActor { [authStore, usageScanner] in
            do {
                if try authStore.goAPIKey() != nil { return true }
            } catch {
                return true
            }
            return usageScanner.hasHostedUsage()
        }
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()

        var goKey: String?
        var authReadError: OpenCodeUsageError?
        do {
            goKey = try await loadOffMainActor { [authStore] in try authStore.goAPIKey() }
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

        var meterLines: [MetricLine] = []
        var plan: String?
        if let goKey {
            switch await fetchGoMeters(apiKey: goKey) {
            case .meters(let lines):
                meterLines = lines
                plan = "Go"
            case .noSubscription:
                AppLog.info(LogTag.plugin("opencode"), "Go usage endpoint: no active subscription")
            case .failed(let error):
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        }

        let scan: OpenCodeUsageScan?
        do {
            scan = try await usageScanner.scan(now: refreshedAt)
        } catch {
            if meterLines.isEmpty {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
            AppLog.warn(
                LogTag.plugin("opencode"),
                "local database unreadable; showing Go meters only: \(error.localizedDescription)"
            )
            scan = nil
        }

        var lines = meterLines
        if let scan {
            SpendTileMapper.appendTokenUsage(
                scan.logScan.series, to: &lines, now: refreshedAt,
                estimated: false,
                unknownModelsByDay: scan.logScan.unknownModelsByDay,
                modelUsage: scan.logScan.modelUsage,
                modelSourceNote: sourceNote
            )
            SpendTileMapper.appendUsageTrend(scan.logScan.series, to: &lines, now: refreshedAt, note: sourceNote)
        }

        if lines.isEmpty {
            if goKey != nil {
                return ProviderSnapshot.error(provider: provider, error: OpenCodeUsageError.noGoSubscription)
            }
            if scan == nil {
                return ProviderSnapshot.error(
                    provider: provider, error: authReadError ?? OpenCodeUsageError.notLoggedIn
                )
            }
        }
        MetricLine.appendNoDataIfNeeded(&lines)

        return ProviderSnapshot.make(
            provider: provider,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: scan.map {
                ProviderUsageHistory(
                    series: $0.logScan.series,
                    modelUsage: $0.logScan.modelUsage,
                    unknownModelsByDay: $0.logScan.unknownModelsByDay
                )
            }
        )
    }

    private enum GoFetch {
        case meters([MetricLine])
        case noSubscription
        case failed(OpenCodeUsageError)
    }

    private func fetchGoMeters(apiKey: String) async -> GoFetch {
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchUsage(apiKey: apiKey)
        } catch {
            return .failed(.connectionFailed)
        }

        if response.statusCode == 401 {
            return .failed(.unauthorized)
        }
        if response.statusCode == 403, OpenCodeUsageMapper.errorType(in: response) == "EntitlementError" {
            return .noSubscription
        }
        guard (200..<300).contains(response.statusCode) else {
            return .failed(.requestFailed(response.statusCode))
        }
        do {
            return .meters(try OpenCodeUsageMapper.meterLines(response))
        } catch let error as OpenCodeUsageError {
            return .failed(error)
        } catch {
            return .failed(.invalidResponse)
        }
    }
}
