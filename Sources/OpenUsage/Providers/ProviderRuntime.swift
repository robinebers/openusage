import Foundation

@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }

    func refresh() async -> Result<ProviderSnapshot, RefreshFailure>
    func forgetHourlyReads()
    func restore(_ snapshot: ProviderSnapshot)
    func refreshHourlyReads(of snapshot: ProviderSnapshot) async -> ProviderSnapshot?
}

extension ProviderRuntime {
    func forgetHourlyReads() {}
    func restore(_ snapshot: ProviderSnapshot) {}
    func refreshHourlyReads(of snapshot: ProviderSnapshot) async -> ProviderSnapshot? { nil }
}

struct ProviderUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

extension MetricLine {
    static func percent(_ label: String, _ used: Double, resetsAt: Date? = nil, periodMs: Int? = nil) -> MetricLine {
        .progress(label: label, used: used, limit: 100, format: .percent, resetsAt: resetsAt, periodDurationMs: periodMs)
    }
}

func loadOffMainActor<T: Sendable>(_ load: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility, operation: load).value
}
