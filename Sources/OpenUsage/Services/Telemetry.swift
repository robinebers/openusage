import Foundation
import PostHog

@MainActor
protocol TelemetrySink: AnyObject {
    func capture(_ event: String, _ properties: [String: Any])
    func flush()
}

@MainActor
final class PostHogTelemetrySink: TelemetrySink {
    /// The project token baked into the build: a client-side, write-only key that ships in every
    /// distributed binary, like any analytics SDK key, so it is safe to commit. The host is region-bound
    /// — a US token will not ingest against the EU host.
    private static let token = "phc_vGEqXEpQNwViyKnMNWvmKWpv8XxMT3yaeYi6gfidr4nf"
    private static let host = "https://us.i.posthog.com"

    init() {
        let config = PostHogConfig(projectToken: Self.token, host: Self.host)
        config.personProfiles = .never
        config.preloadFeatureFlags = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.optOut = false
        // NOTE: this local flag is necessary but NOT sufficient — posthog-ios also gates the integration
        // on a SERVER-side switch (remote config `errorTracking.autocaptureExceptions`). "Exception
        // autocapture" must be enabled in the PostHog project settings, and because the SDK reads it from
        // cache at init, capture arms on the *second* launch after enabling (first launch fetches+caches).
        config.errorTrackingConfig.autoCapture = true
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.optIn()

        PostHogSDK.shared.register([
            "app_version": AppInfo.version,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ])
        AppLog.info(.config, "telemetry initialized")
    }

    func capture(_ event: String, _ properties: [String: Any]) {
        PostHogSDK.shared.capture(event, properties: properties)
    }

    func flush() {
        PostHogSDK.shared.flush()
    }
}
