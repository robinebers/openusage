import Foundation

/// When a widget's timeline entries fall. WidgetKit treats the requested reload time as a minimum and can
/// postpone it to fit its daily budget, so the timeline carries evenly spaced entries well past that time
/// and a widget redraws on schedule from data it already has.
public enum WidgetTimelineSchedule {
    public static let staleInterval: TimeInterval = 30 * 60

    /// The longest gap between two entries.
    public static let entrySpacing: TimeInterval = 30 * 60

    /// How far ahead entries are written.
    public static let horizon: TimeInterval = 4 * 60 * 60

    /// Regular entries plus upcoming reset deadlines, so expired windows can show static "soon" text.
    public static func entryDates(from now: Date, resetDates: [Date] = []) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        let regular = stride(from: 0, through: horizon, by: entrySpacing).map { now.addingTimeInterval($0) }
        return Set(regular + resetDates.filter { $0 > now && $0 <= end }).sorted()
    }
}
