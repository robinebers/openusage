import Foundation

/// One signed-in account and its provider usage endpoint.
///
/// `refresh()` returns the latest snapshot. Build its `lines` from the app's small metric vocabulary,
/// choosing the case by the shape of the value:
/// - `.progress` — a bounded meter with a `used`/`limit` and a `format` (percent, dollars, or count). Use
///   for anything with a ceiling: session/weekly quotas, credits with a cap. Add `resetsAt` when the
///   window resets at a known time.
/// - `.values` — one or more typed, unbounded numbers.
/// - `.badge` — a short status pill (e.g. "Disabled", or a pay-as-you-go cap). Use for state, not a number
///   to fill a bar with.
///
/// On failure, return `ProviderSnapshot(provider:failure:)` with `RefreshFailure(error:)` from a typed
/// provider error.
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }

    func refresh() async -> ProviderSnapshot
    /// Makes the next `refresh()` ask again for the reads it reuses for an hour; the store calls it before
    /// a forced refresh.
    func forgetHourlyReads()
    /// Shown the account's saved snapshot before its first refresh, so a runtime that reads its plan
    /// outside a pass can keep showing the saved one until it asks.
    func restore(_ snapshot: ProviderSnapshot)
    /// The secondary-reads slot, halfway between passes: the reads a runtime keeps out of a pass, applied
    /// to the account's current `snapshot`; `nil` when nothing changed.
    func refreshHourlyReads(of snapshot: ProviderSnapshot) async -> ProviderSnapshot?
}

extension ProviderRuntime {
    func forgetHourlyReads() {}
    func restore(_ snapshot: ProviderSnapshot) {}
    func refreshHourlyReads(of snapshot: ProviderSnapshot) async -> ProviderSnapshot? { nil }
}

/// What one refresh read: the plan name, if the provider reports one, and the account's metric lines.
struct ProviderUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

extension MetricLine {
    /// A percent-used meter out of 100.
    static func percent(_ label: String, _ used: Double, resetsAt: Date? = nil, periodMs: Int? = nil) -> MetricLine {
        .progress(label: label, used: used, limit: 100, format: .percent, resetsAt: resetsAt, periodDurationMs: periodMs)
    }
}

/// Run a blocking, `Sendable` credential load off the MainActor.
///
/// Credential vault reads block the calling thread for as long as a Keychain prompt waits for the user.
/// They run at the top of a provider's `@MainActor refresh()`,
/// so calling them inline would freeze the popover and the periodic-refresh loop. Offloading to a
/// detached task moves the wait onto a background executor; the `Sendable` result crosses back cleanly.
/// It is awaited immediately, so it reads like a normal call while no longer blocking the actor.
func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility, operation: load).value
}
