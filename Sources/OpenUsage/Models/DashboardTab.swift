import Foundation

enum DashboardTab: String, Hashable, Sendable, CaseIterable {
    static let key = "dashboardTab"

    case priority
    case allMetrics

    var label: String {
        switch self {
        case .priority: "Priority"
        case .allMetrics: "All Metrics"
        }
    }
}
