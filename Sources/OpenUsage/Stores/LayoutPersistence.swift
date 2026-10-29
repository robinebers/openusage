import Foundation

/// Saves the layout under a key 0.7.x never reads, so its own layout stays as it left it for a downgrade.
@MainActor
final class LayoutPersistence {
    static let key = "openusage.layout.v2"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> LayoutState? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        do {
            return try JSONDecoder().decode(LayoutState.self, from: data)
        } catch {
            AppLog.warn(.config, "saved layout failed to decode; starting a new one: \(error.localizedDescription)")
            return nil
        }
    }

    func save(_ state: LayoutState) {
        do {
            defaults.set(try JSONEncoder().encode(state), forKey: Self.key)
        } catch {
            AppLog.warn(.config, "failed to persist layout: \(error.localizedDescription)")
        }
    }
}
