import Foundation

enum LayoutOrdering {
    static func defaultMetricOrder(registry: WidgetRegistry) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for provider in registry.providers {
            result[provider.id] = registry.descriptors(for: provider.id).map(\.id)
        }
        return result
    }

    static func normalizedMetricOrder(
        _ saved: [String: [String]],
        registry: WidgetRegistry
    ) -> [String: [String]] {
        var fallback = defaultMetricOrder(registry: registry)
        for provider in registry.providers {
            let valid = registry.descriptors(for: provider.id).map(\.id)
            if let savedIDs = saved[provider.id] {
                fallback[provider.id] = normalizedMetricIDs(savedIDs, validIDs: valid)
            }
        }
        return fallback
    }

    static func normalizedMetricIDs(_ saved: [String], validIDs: [String]) -> [String] {
        let validSet = Set(validIDs)
        var seen = Set<String>()
        var ordered = saved.filter { id in
            guard validSet.contains(id), !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
        ordered.append(contentsOf: validIDs.filter { !seen.contains($0) })
        return ordered
    }
}
