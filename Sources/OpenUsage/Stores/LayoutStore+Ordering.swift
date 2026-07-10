extension LayoutStore {
    func metricOrder(for providerID: String) -> [String] {
        metricOrderByProvider[providerID] ?? []
    }

    static func mergingMissingMetrics(into ordered: [String], previous: [String]) -> [String] {
        let orderedSet = Set(ordered)
        var result: [String] = []
        var emitted = Set<String>()
        var orderedIndex = ordered.startIndex

        func emitDesiredRows(through id: String) {
            while orderedIndex < ordered.endIndex {
                let next = ordered[orderedIndex]
                orderedIndex = ordered.index(after: orderedIndex)
                if emitted.insert(next).inserted {
                    result.append(next)
                }
                if next == id { break }
            }
        }

        for id in previous {
            if orderedSet.contains(id) {
                emitDesiredRows(through: id)
            } else if emitted.insert(id).inserted {
                result.append(id)
            }
        }

        while orderedIndex < ordered.endIndex {
            let next = ordered[orderedIndex]
            orderedIndex = ordered.index(after: orderedIndex)
            if emitted.insert(next).inserted {
                result.append(next)
            }
        }

        return result
    }

    /// Pure reorder: remove `dragged`, reinsert it adjacent to `target` (after it when moving down, before
    /// it when moving up). Returns nil when either id is missing or they're identical. Mirrors the proven
    /// macOS drag-reorder math from crafcat7/Peakmon (Apache-2.0).
    static func reordered(_ ids: [String], dragged: String, target: String) -> [String]? {
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target) else { return nil }
        var next = ids
        next.remove(at: from)
        guard let adjusted = next.firstIndex(of: target) else { return nil }
        let insert = from < to ? adjusted + 1 : adjusted
        next.insert(dragged, at: min(insert, next.count))
        return next
    }
}
