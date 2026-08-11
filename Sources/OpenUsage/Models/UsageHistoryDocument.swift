import Foundation

/// One Mac's presentation-free usage history in the private iCloud container.
struct UsageHistoryDocument: Hashable, Sendable, Codable, Identifiable {
    static let currentSchema = "openusage.history.v1"

    var schema: String = currentSchema
    var deviceID: String
    var deviceName: String
    var updatedAt: Date
    var providers: [String: ProviderUsageHistory]

    var id: String { deviceID }

    static func newestByDevice(_ documents: [UsageHistoryDocument]) -> [UsageHistoryDocument] {
        var newest: [String: UsageHistoryDocument] = [:]
        for document in documents {
            if let existing = newest[document.deviceID], existing.updatedAt >= document.updatedAt {
                continue
            }
            newest[document.deviceID] = document
        }
        return Array(newest.values)
    }

    func validate() throws {
        guard schema == Self.currentSchema else { throw UsageHistoryDocumentError.unsupportedSchema }
        guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw UsageHistoryDocumentError.invalidDevice }

        for (providerID, history) in providers {
            guard providerID.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil else {
                throw UsageHistoryDocumentError.invalidProvider(providerID)
            }
            var seriesDays: Set<String> = []
            for day in history.series.daily {
                guard seriesDays.insert(day.date).inserted else { throw UsageHistoryDocumentError.duplicateDay(day.date) }
                try Self.validate(date: day.date, tokens: day.totalTokens, cost: day.costUSD)
            }
            var modelDays: Set<String> = []
            for day in history.modelUsage?.daily ?? [] {
                guard Self.isDayKey(day.date) else { throw UsageHistoryDocumentError.invalidDay(day.date) }
                guard modelDays.insert(day.date).inserted else { throw UsageHistoryDocumentError.duplicateDay(day.date) }
                var modelNames: Set<String> = []
                for model in day.models {
                    guard modelNames.insert(model.model.lowercased()).inserted else {
                        throw UsageHistoryDocumentError.duplicateModel(model.model)
                    }
                    try Self.validate(model: model)
                }
            }
            for day in history.unknownModelsByDay.keys where !Self.isDayKey(day) {
                throw UsageHistoryDocumentError.invalidDay(day)
            }
        }
    }

    private static func validate(date: String, tokens: Int, cost: Double?) throws {
        guard isDayKey(date) else { throw UsageHistoryDocumentError.invalidDay(date) }
        guard tokens >= 0, cost.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw UsageHistoryDocumentError.invalidValue
        }
    }

    private static func validate(model: ModelUsageEntry) throws {
        guard !model.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.totalTokens >= 0,
              model.costUSD.map({ $0.isFinite && $0 >= 0 }) ?? true
        else { throw UsageHistoryDocumentError.invalidValue }
        for variant in model.variants ?? [] {
            guard !variant.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  variant.totalTokens >= 0,
                  variant.costUSD.map({ $0.isFinite && $0 >= 0 }) ?? true
            else { throw UsageHistoryDocumentError.invalidValue }
        }
    }

    private static func isDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month)
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let monthDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthDate)
        else { return false }
        return dayRange.contains(day)
    }
}

enum UsageHistoryDocumentError: Error, LocalizedError, Equatable {
    case unsupportedSchema
    case invalidDevice
    case invalidProvider(String)
    case invalidDay(String)
    case duplicateDay(String)
    case duplicateModel(String)
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "This Mac wrote a newer usage-history format. Update OpenUsage."
        case .invalidDevice: "The synced Mac identity is invalid."
        case .invalidProvider: "The synced provider identifier is invalid."
        case .invalidDay: "The synced history contains an invalid date."
        case .duplicateDay: "The synced history contains the same date more than once."
        case .duplicateModel: "The synced history contains the same model more than once."
        case .invalidValue: "The synced history contains an invalid usage value."
        }
    }
}
