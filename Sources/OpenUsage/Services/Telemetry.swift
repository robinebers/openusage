import Foundation
import PostHog

/// Build-time configuration for the PostHog project. The project token is a client-side, write-only
/// key (it ships in every distributed binary, like any analytics SDK key), so it is safe to commit;
/// an `OPENUSAGE_POSTHOG_TOKEN` environment override is supported for local testing without editing
/// source. The host is region-bound — a US token will not ingest against the EU host.
enum TelemetryConfig {
    /// Sentinel meaning "no real token configured" — the sink stays inert (no setup, no network) while
    /// the resolved token equals this. Do NOT change this value.
    static let placeholderToken = "phc_REPLACE_ME"

    /// The project token baked into the build. Replace `phc_REPLACE_ME` with the real US-region
    /// `phc_…` key (safe to commit — it's a client write-only key), or leave it and set
    /// `OPENUSAGE_POSTHOG_TOKEN` at runtime for local testing.
    private static let bakedToken = "phc_vGEqXEpQNwViyKnMNWvmKWpv8XxMT3yaeYi6gfidr4nf"

    static var token: String {
        let env = ProcessInfo.processInfo.environment["OPENUSAGE_POSTHOG_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        return bakedToken
    }

    /// US cloud. Switch to "https://eu.i.posthog.com" only with an EU-region project token.
    static let host = "https://us.i.posthog.com"
}

/// The transport seam telemetry is emitted through. Abstracted from PostHog so the recorder's
/// daily-rollup/dedup logic can be unit-tested against a fake sink.
@MainActor
protocol TelemetrySink: AnyObject {
    func capture(_ event: String, _ properties: [String: Any])
    /// Mirror the user's opt-out choice onto the underlying SDK at runtime.
    func setEnabled(_ enabled: Bool)
    func flush()
}

/// Anonymous, opt-out PostHog sink. No `identify()`/`group()`/`alias()`, `personProfiles = .never`,
/// and only IDs/counts/enums are ever sent — never the free-form error message (the file log's
/// `LogRedaction` does not cover a network transport). When no real project token is configured the
/// sink is inert (the app still builds and the toggle still works), so dev builds never phone home.
@MainActor
final class PostHogTelemetrySink: TelemetrySink {
    /// Crash / uncaught-exception autocapture is gated on the SAME opt-out as usage telemetry, decided
    /// here so the opt-out contract is unit-testable without touching the `PostHogSDK.shared` singleton.
    /// Gating *install* (not just sending) on the opt-out means an opted-out launch installs no signal/
    /// exception handler and writes no crash report to disk — honoring privacy.md's "nothing while off".
    nonisolated static func errorAutocaptureEnabled(telemetryEnabled: Bool) -> Bool { telemetryEnabled }

    private let configured: Bool

    init(enabled: Bool, token: String = TelemetryConfig.token, host: String = TelemetryConfig.host) {
        guard token.hasPrefix("phc_"), token != TelemetryConfig.placeholderToken else {
            configured = false
            AppLog.info(.config, "telemetry inert: no PostHog project token configured")
            return
        }
        configured = true

        let config = PostHogConfig(projectToken: token, host: host)
        // Fully anonymous: no person profiles, no anonymous->identified merge.
        config.personProfiles = .never
        // We use no feature flags and emit our own daily rollups, so skip both startup fetches/autocapture.
        config.preloadFeatureFlags = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        // Start in the user's chosen state before any event can fire.
        config.optOut = !enabled
        // Crash / uncaught-exception autocapture, gated on the SAME opt-out (anonymous `$exception`
        // events, sent on the NEXT launch after a crash). It captures Mach exceptions, POSIX signals,
        // and uncaught NSExceptions; Swift traps may surface as a bare `SIGTRAP` without the message —
        // the symbolicated stack (dSYMs uploaded from release.yml) is what makes them actionable.
        // Gating install on `enabled` (not relying on `optOut` alone) means an opted-out launch wires
        // up no handler and writes nothing to disk. A runtime opt-IN therefore activates crash capture
        // from the next launch; `optOut` (mirrored by `setEnabled`) still hard-stops sending in-session.
        // NOTE: this local flag is necessary but NOT sufficient — posthog-ios also gates the integration
        // on a SERVER-side switch (remote config `errorTracking.autocaptureExceptions`). "Exception
        // autocapture" must be enabled in the PostHog project settings, and because the SDK reads it from
        // cache at init, capture arms on the *second* launch after enabling (first launch fetches+caches).
        // Never reference sessionReplay / surveys / captureElementInteractions / tracingHeaders here:
        // they do not exist on a macOS target.
        config.errorTrackingConfig.autoCapture = Self.errorAutocaptureEnabled(telemetryEnabled: enabled)
        PostHogSDK.shared.setup(config)

        // Super properties ride on every subsequent event (anonymous, non-PII).
        PostHogSDK.shared.register([
            "app_version": AppInfo.version,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ])
        AppLog.info(.config, "telemetry initialized (enabled=\(enabled))")
    }

    func capture(_ event: String, _ properties: [String: Any]) {
        guard configured else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    func setEnabled(_ enabled: Bool) {
        guard configured else { return }
        if enabled { PostHogSDK.shared.optIn() } else { PostHogSDK.shared.optOut() }
    }

    func flush() {
        guard configured else { return }
        PostHogSDK.shared.flush()
    }
}
