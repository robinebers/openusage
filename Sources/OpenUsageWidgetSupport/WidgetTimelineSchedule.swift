import Foundation

/// When a widget's timeline entries fall. WidgetKit treats the requested reload time as a minimum and can
/// postpone it to fit its daily budget, so the timeline carries evenly spaced entries well past that time
/// and a widget redraws on schedule from data it already has.
public enum WidgetTimelineSchedule {
    /// The longest gap between two entries. Countdown layouts reserve room for the text they show until
    /// the next entry.
    public static let entrySpacing: TimeInterval = 30 * 60

    /// How far ahead entries are written.
    public static let horizon: TimeInterval = 4 * 60 * 60

    /// `now`, then one entry per `entrySpacing` through `horizon`.
    public static func entryDates(from now: Date) -> [Date] {
        stride(from: 0, through: horizon, by: entrySpacing).map { now.addingTimeInterval($0) }
    }
}
