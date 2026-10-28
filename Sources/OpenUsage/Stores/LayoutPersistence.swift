import Foundation

@MainActor
final class LayoutPersistence {
    private let defaults: UserDefaults
    private let keys: Keys

    init(defaults: UserDefaults, storageKey: String) {
        self.defaults = defaults
        self.keys = Keys(storageKey: storageKey)
    }

    func loadHidden() -> [String]? { defaults.stringArray(forKey: keys.hidden) }
    func loadProviderOrder() -> [String]? { decode([String].self, forKey: keys.providerOrder) }
    func loadMetricOrder() -> [String: [String]]? {
        decode([String: [String]].self, forKey: keys.metricOrder)
    }

    func loadPins() -> [String]? { defaults.stringArray(forKey: keys.pins) }

    func saveHidden(_ value: Set<String>) { defaults.set(value.sorted(), forKey: keys.hidden) }
    func saveProviderOrder(_ value: [String]) { encode(value, forKey: keys.providerOrder) }
    func saveMetricOrder(_ value: [String: [String]]) { encode(value, forKey: keys.metricOrder) }

    func savePins(_ value: Set<String>) { defaults.set(Array(value), forKey: keys.pins) }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            AppLog.warn(.config, "failed to persist layout '\(key)': \(error.localizedDescription)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.warn(.config, "saved layout '\(key)' failed to decode; reseeding default: \(error.localizedDescription)")
            return nil
        }
    }

    private struct Keys {
        let hidden: String
        let providerOrder: String
        let metricOrder: String
        let pins: String

        init(storageKey: String) {
            hidden = "\(storageKey).hiddenMetrics"
            providerOrder = "\(storageKey).providerOrder"
            metricOrder = "\(storageKey).metricOrderByProvider"
            pins = "\(storageKey).menuBarPins"
        }
    }
}
