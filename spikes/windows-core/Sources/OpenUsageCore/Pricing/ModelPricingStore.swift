import Foundation

/// Owns the app's model pricing data: bundled snapshots for offline first launch, on-disk caches in
/// Application Support, and daily refreshes from the live feeds (LiteLLM, models.dev, and the
/// OpenUsage pricing supplement on gh-pages). `current()` never blocks on the network — it serves
/// the freshest data on hand and revalidates in the background (stale-while-revalidate).
actor ModelPricingStore {
    static let shared = ModelPricingStore()

    /// Refetch a source this long after its last success.
    private static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// Retry a failed source after this long (keeps failure logs from repeating every provider pass).
    private static let failureRetryInterval: TimeInterval = 30 * 60

    enum SourceID: String, CaseIterable, Codable, Sendable {
        case litellm
        case modelsDev = "models_dev"
        case supplement
    }

    private struct SourceState: Codable {
        var etag: String?
        var fetchedAt: Date?
        var failedAt: Date?
    }

    private let http: any HTTPClient
    private let cacheDirectory: URL
    private let now: @Sendable () -> Date
    private let sourceURLs: [SourceID: URL]
    private let bundledData: @Sendable (String) -> Data?

    private var loaded = false
    private var pricing: ModelPricing = .empty
    private var sourceStates: [SourceID: SourceState] = [:]
    private var refreshTask: Task<Void, Never>?

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        cacheDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        sourceURLs: [SourceID: URL] = ModelPricingStore.defaultSourceURLs,
        bundledData: @escaping @Sendable (String) -> Data? = ModelPricingStore.bundledResourceData
    ) {
        self.http = http
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory
        self.now = now
        self.sourceURLs = sourceURLs
        self.bundledData = bundledData
    }

    static let defaultSourceURLs: [SourceID: URL] = [
        .litellm: URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!,
        .modelsDev: URL(string: "https://models.dev/api.json")!,
        .supplement: URL(string: "https://robinebers.github.io/openusage/pricing_supplement.json")!
    ]

    private static var defaultCacheDirectory: URL {
        WellKnownPaths.applicationSupport
            .appendingPathComponent("OpenUsage/pricing", isDirectory: true)
    }

    private static func bundledResourceData(_ resourceName: String) -> Data? {
        guard let url = Bundle.openUsageResources.url(forResource: resourceName, withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// The pricing snapshot to use for a scan/parse pass. Kicks a background refresh when any
    /// source is due; the refreshed data is picked up by the next call.
    func current() -> ModelPricing {
        loadIfNeeded()
        if refreshTask == nil, SourceID.allCases.contains(where: isDue) {
            refreshTask = Task { await self.refreshDueSources() }
        }
        return pricing
    }

    /// Runs any due fetches to completion — for tests and deterministic refresh points.
    func refreshNow() async {
        loadIfNeeded()
        if refreshTask == nil {
            refreshTask = Task { await self.refreshDueSources() }
        }
        await refreshTask?.value
    }

    // MARK: - Initial load (bundled + disk cache)

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        sourceStates = readSourceStates()
        rebuildPricing()
    }

    private func rebuildPricing() {
        pricing = ModelPricing(
            supplement: loadSupplement(),
            primary: loadCatalog(.litellm, parse: PricingCatalogCodecs.catalogFromCompact),
            secondary: loadCatalog(.modelsDev, parse: PricingCatalogCodecs.catalogFromCompact)
        )
    }

    private func loadSupplement() -> PricingSupplement {
        if let cached = readCache(.supplement) {
            do {
                return try PricingSupplement.decode(from: cached)
            } catch {
                AppLog.warn("pricing", "cached supplement unreadable, using bundled: \(error.localizedDescription)")
            }
        }
        guard let bundled = bundledData("pricing_supplement") else {
            AppLog.error("pricing", "bundled pricing_supplement.json missing")
            return PricingSupplement()
        }
        do {
            return try PricingSupplement.decode(from: bundled)
        } catch {
            AppLog.error("pricing", "bundled pricing_supplement.json unreadable: \(error.localizedDescription)")
            return PricingSupplement()
        }
    }

    /// A catalog is the bundled snapshot with the fetched cache merged on top — cached entries win,
    /// but snapshot-only models survive if the live feed ever drops them.
    private func loadCatalog(_ source: SourceID, parse: (Data) throws -> PricingCatalog) -> PricingCatalog {
        var catalog = PricingCatalog()
        let resourceName = source == .litellm ? "pricing_litellm_snapshot" : "pricing_models_dev_snapshot"
        if let bundled = bundledData(resourceName) {
            do {
                catalog = try PricingCatalogCodecs.catalogFromCompact(bundled)
            } catch {
                AppLog.error("pricing", "bundled \(resourceName).json unreadable: \(error.localizedDescription)")
            }
        } else {
            AppLog.error("pricing", "bundled \(resourceName).json missing")
        }
        if let cached = readCache(source) {
            do {
                catalog = catalog.merging(try parse(cached))
            } catch {
                AppLog.warn("pricing", "cached \(source.rawValue) catalog unreadable, using bundled: \(error.localizedDescription)")
            }
        }
        return catalog
    }

    // MARK: - Refresh

    private func isDue(_ source: SourceID) -> Bool {
        let state = sourceStates[source] ?? SourceState()
        if let failedAt = state.failedAt, now().timeIntervalSince(failedAt) < Self.failureRetryInterval {
            return false
        }
        guard let fetchedAt = state.fetchedAt else { return true }
        return now().timeIntervalSince(fetchedAt) >= Self.refreshInterval
    }

    private func refreshDueSources() async {
        defer { refreshTask = nil }
        var changed = false
        for source in SourceID.allCases where isDue(source) {
            if await fetch(source) {
                changed = true
            }
        }
        if changed {
            rebuildPricing()
            AppLog.info("pricing", "pricing refreshed (\(pricing.primary.entries.count) LiteLLM, \(pricing.secondary.entries.count) models.dev, \(pricing.supplement.pricing.count) supplement models)")
        }
        writeSourceStates()
    }

    /// Fetches one source and updates its cache file. Returns true when new data was stored.
    private func fetch(_ source: SourceID) async -> Bool {
        guard let url = sourceURLs[source] else { return false }
        var state = sourceStates[source] ?? SourceState()
        var request = HTTPRequest(method: "GET", url: url, timeout: 30)
        if let etag = state.etag {
            request.headers["If-None-Match"] = etag
        }
        do {
            let response = try await http.send(request)
            switch response.statusCode {
            case 200:
                let cacheData = try validatedCacheData(source, body: response.body)
                try writeCache(source, data: cacheData)
                state.etag = response.header("etag")
                state.fetchedAt = now()
                state.failedAt = nil
                sourceStates[source] = state
                return true
            case 304:
                state.fetchedAt = now()
                state.failedAt = nil
                sourceStates[source] = state
                return false
            default:
                throw PricingFetchError.httpStatus(response.statusCode)
            }
        } catch {
            state.failedAt = now()
            sourceStates[source] = state
            AppLog.warn("pricing", "\(source.rawValue) refresh failed, keeping cached data: \(error.localizedDescription)")
            return false
        }
    }

    /// Parses the fetched body (throwing on garbage so it never replaces a good cache) and returns
    /// the bytes to persist — compacted for the big catalogs, verbatim for the supplement.
    private func validatedCacheData(_ source: SourceID, body: Data) throws -> Data {
        switch source {
        case .litellm:
            return try PricingCatalogCodecs.compactData(from: try PricingCatalogCodecs.catalogFromLiteLLM(body))
        case .modelsDev:
            return try PricingCatalogCodecs.compactData(from: try PricingCatalogCodecs.catalogFromModelsDev(body))
        case .supplement:
            _ = try PricingSupplement.decode(from: body)
            return body
        }
    }

    // MARK: - Disk cache

    private func cacheFile(_ source: SourceID) -> URL {
        cacheDirectory.appendingPathComponent("\(source.rawValue).json")
    }

    private var stateFile: URL {
        cacheDirectory.appendingPathComponent("state.json")
    }

    private func readCache(_ source: SourceID) -> Data? {
        try? Data(contentsOf: cacheFile(source))
    }

    private func writeCache(_ source: SourceID, data: Data) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: cacheFile(source), options: .atomic)
    }

    private func readSourceStates() -> [SourceID: SourceState] {
        guard let data = try? Data(contentsOf: stateFile),
              let states = try? JSONDecoder().decode([SourceID: SourceState].self, from: data) else {
            return [:]
        }
        return states
    }

    private func writeSourceStates() {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(sourceStates)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            AppLog.warn("pricing", "could not persist pricing fetch state: \(error.localizedDescription)")
        }
    }
}

private enum PricingFetchError: Error, LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code)"
        }
    }
}
