import Foundation

/// Builds daily token/cost estimates for Antigravity from Antigravity CLI local logs.
///
/// Scans `~/.gemini/antigravity-cli/brain/**/.system_generated/logs/transcript.jsonl` and
/// `~/.gemini/tmp/**/*.jsonl` for step & completion records with model & token accounting.
struct AntigravityLogUsageScanner: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("antigravity"),
            warning: readFailureWarning
        )
    }

    /// Default search roots under `~/.gemini`.
    var logRoots: [URL] {
        let base = homeDirectory().appendingPathComponent(".gemini")
        return [
            base.appendingPathComponent("antigravity-cli/brain"),
            base.appendingPathComponent("tmp")
        ]
    }

    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        var allFiles: [JSONLScanning.DiscoveredFile] = []
        for root in logRoots {
            if files.exists(root.path) {
                allFiles.append(contentsOf: JSONLScanning.jsonlFiles(under: root))
            }
        }

        guard !allFiles.isEmpty else {
            await readFailureReporter.update(checkedPaths: Set(logRoots.map(\.path)), failingPaths: [])
            return nil
        }

        var accumulator = DailyUsageAccumulator()
        var checkedPaths: Set<String> = []
        var failingPaths: Set<String> = []

        for discovered in allFiles {
            checkedPaths.insert(discovered.path)
            do {
                let text = try files.readText(discovered.path)
                Self.parse(text, since: since, pricing: pricing, into: &accumulator)
            } catch {
                failingPaths.insert(discovered.path)
            }
        }

        await readFailureReporter.update(checkedPaths: checkedPaths, failingPaths: failingPaths)
        let scanResult = accumulator.build()
        if scanResult.series.daily.isEmpty && scanResult.unknownModelsByDay.isEmpty {
            return nil
        }
        return scanResult
    }

    /// Single chronological pass over transcript JSONL files.
    static func parse(_ text: String, since: Date, pricing: ModelPricing, into accumulator: inout DailyUsageAccumulator) {
        var currentModel: String = "gemini-3.6-flash"

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let object = ProviderParse.jsonObject(data)
            else { continue }

            // Extract date
            let timestamp: Date? = {
                if let raw = object["created_at"] as? String { return OpenUsageISO8601.date(from: raw) }
                if let raw = object["timestamp"] as? String { return OpenUsageISO8601.date(from: raw) }
                if let ts = ProviderParse.number(object["time"]) { return Date(timeIntervalSince1970: ts) }
                return nil
            }()

            // Track model updates
            if let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                currentModel = model
            }

            guard let date = timestamp, date >= since else { continue }

            // Check if usage/tokens dict is present
            let tokensObj = object["tokens"] as? [String: Any]
                ?? object["usage"] as? [String: Any]

            guard let tokensObj else { continue }

            let inputTokens = Int(ProviderParse.number(tokensObj["input"]) ?? ProviderParse.number(tokensObj["input_tokens"]) ?? 0)
            let cacheReadTokens = Int(ProviderParse.number(tokensObj["cached"]) ?? ProviderParse.number(tokensObj["cache_read_input_tokens"]) ?? 0)
            let outputTokens = Int(ProviderParse.number(tokensObj["output"]) ?? ProviderParse.number(tokensObj["output_tokens"]) ?? 0)
            let reasoningTokens = Int(ProviderParse.number(tokensObj["thoughts"]) ?? ProviderParse.number(tokensObj["reasoning_tokens"]) ?? 0)

            let totalOutput = outputTokens + reasoningTokens
            let totalTokens = inputTokens + cacheReadTokens + totalOutput
            guard totalTokens > 0 else { continue }

            let day = DailyUsageAccumulator.dayKey(from: date)
            let breakdown = TokenBreakdown(input: inputTokens, cacheRead: cacheReadTokens, output: totalOutput)

            guard let cost = pricing.estimatedCostDollars(model: currentModel, tokens: breakdown) else {
                accumulator.addUnknownModel(day: day, model: currentModel)
                continue
            }
            accumulator.add(day: day, tokens: totalTokens, cost: cost, model: currentModel)
        }
    }
}
