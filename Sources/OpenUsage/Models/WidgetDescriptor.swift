import Foundation

/// What a provider offers to the gallery: identity, render kind, and a sample of the
/// data it would feed (mocked). The display name is the single `sample.title`, shared
/// by the tile and the gallery — there is no separate title string.
struct WidgetDescriptor: Identifiable, Hashable {
    let id: String                 // "claude.session"
    let providerID: String
    let metricLabel: String
    let sample: WidgetData

    /// The one display name for this widget (tile + gallery).
    var title: String { sample.title }

    static func == (lhs: WidgetDescriptor, rhs: WidgetDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
