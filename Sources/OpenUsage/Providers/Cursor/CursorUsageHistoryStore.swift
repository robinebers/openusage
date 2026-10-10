import Foundation

struct CursorUsageDay: Codable, Sendable, Equatable {
    var models: [String: TokenBreakdown]

    mutating func add(_ tokens: TokenBreakdown, for model: String) {
        var existing = models[model] ?? TokenBreakdown()
        existing.input += tokens.input
        existing.cacheWrite5m += tokens.cacheWrite5m
        existing.cacheWrite1h += tokens.cacheWrite1h
        existing.cacheRead += tokens.cacheRead
        existing.output += tokens.output
        existing.isFast = existing.isFast || tokens.isFast
        models[model] = existing
    }
}

struct CursorUsageHistoryStore: Sendable {
    private struct File: Codable {
        var schemaVersion: Int
        var userID: String
        var timeZone: String
        var days: [String: CursorUsageDay]
    }

    private static let schemaVersion = 1

    var directory: URL

    init(directory: URL = CursorUsageHistoryStore.defaultDirectory) {
        self.directory = directory
    }

    func load(userID: String, timeZone: String) -> [String: CursorUsageDay] {
        let url = fileURL(userID: userID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            guard file.schemaVersion == Self.schemaVersion,
                  file.userID == userID,
                  file.timeZone == timeZone
            else {
                return [:]
            }
            return file.days
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "usage history cache could not be read")
            return [:]
        }
    }

    func save(_ days: [String: CursorUsageDay], userID: String, timeZone: String) {
        let file = File(
            schemaVersion: Self.schemaVersion,
            userID: userID,
            timeZone: timeZone,
            days: days
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL(userID: userID), options: .atomic)
        } catch {
            AppLog.warn(LogTag.plugin("cursor"), "usage history cache could not be saved")
        }
    }

    private func fileURL(userID: String) -> URL {
        directory.appendingPathComponent("\(JSONLScanCachePaths.stableFingerprint(userID)).json")
    }

    private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenUsage/cursor-usage-history", isDirectory: true)
    }
}
