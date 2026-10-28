import Foundation

enum MetricPeriod {
    static let sessionMs = 5 * 60 * 60 * 1000
    static let dayMs = 24 * 60 * 60 * 1000
    static let weekMs = 7 * dayMs
    static let monthMs = 30 * dayMs
}
