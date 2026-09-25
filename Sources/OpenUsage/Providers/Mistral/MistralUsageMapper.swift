import Foundation

enum MistralUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .sessionExpired:
            return "Your Mistral session expired. Sign in to admin.mistral.ai and try again."
        }
    }
}

/// One included monthly allowance as Mistral reports it — the reported percentage is the source
/// of truth; the budget amount only enriches the row when present.
struct MistralAllowance: Hashable, Sendable {
    var percentUsed: Double
    var limit: Double?
    var currency: String?
    var resetsAt: Date?
}

/// Builds metric lines from Mistral Admin's subscription page (the Next.js `__next_f` flight
/// stream carrying `api_budget` / `vibe_budget` objects) and, when that page reports no Vibe
/// allowance, the console's `billing.vibeUsage` tRPC reply. Both routes are undocumented
/// internal endpoints Mistral's own console uses; the shapes are stable in practice. The mapper
/// is pure (no I/O) so it tests cleanly against sample payloads.
enum MistralUsageMapper {
    /// A subscription month is a billing month; the cadence sorts the row, the reported reset
    /// date drives the countdown.
    static let monthlyPeriodMs = 30 * 24 * 60 * 60 * 1000

    static let apiLabel = "API"
    static let vibeLabel = "Vibe"

    /// The meter lines from the subscription page's HTML, optionally patched by the Vibe
    /// tRPC reply. Every source is best-effort: with no allowance at all the card reads
    /// "No usage data" rather than erroring — an account without a subscription legitimately has
    /// nothing to meter.
    static func map(subscriptionHTML: String?, vibeBody: Data?) -> [MetricLine] {
        var allowances = allowancesFromSubscriptionPage(subscriptionHTML ?? "")
        if allowances.vibe == nil, let vibeBody {
            allowances.vibe = allowanceFromVibeReply(vibeBody)
        }
        var lines: [MetricLine] = []
        if let api = allowances.api {
            lines.append(allowanceLine(api, label: apiLabel))
        }
        if let vibe = allowances.vibe {
            lines.append(allowanceLine(vibe, label: vibeLabel))
        }
        MetricLine.appendNoDataIfNeeded(&lines)
        return lines
    }

    // MARK: - Subscription page (Next.js flight stream)

    /// The allowances from the subscription page's `self.__next_f.push` chunks: the strings are
    /// joined into one stream, and each distinct `api_budget` / `vibe_budget` object becomes an
    /// allowance. When the stream carries two different objects under one name, neither is taken —
    /// there is no telling which is this account's.
    static func allowancesFromSubscriptionPage(_ html: String) -> (api: MistralAllowance?, vibe: MistralAllowance?) {
        let stream = flightStream(in: html)
        return (
            api: budget(named: "api_budget", in: stream),
            vibe: budget(named: "vibe_budget", in: stream)
        )
    }

    /// Join the page's `self.__next_f.push([1, "…"])` chunk strings into one stream.
    static func flightStream(in html: String) -> String {
        let marker = "self.__next_f.push("
        var chunks: [String] = []
        var cursor = html.startIndex
        while let found = html.range(of: marker, range: cursor..<html.endIndex) {
            cursor = found.upperBound
            guard let start = html[cursor...].firstIndex(where: { !$0.isWhitespace }),
                  html[start] == "[",
                  let end = containerEnd(in: html, from: start)
            else { continue }
            if let array = try? JSONSerialization.jsonObject(with: Data(html[start..<end].utf8)) as? [Any],
               array.count >= 2,
               (array[0] as? NSNumber)?.intValue == 1,
               let chunk = array[1] as? String {
                chunks.append(chunk)
            }
            cursor = end
        }
        return chunks.joined()
    }

    /// Where the JSON array or object opening at `start` closes, skipping whatever is inside
    /// strings. Nil if it never closes or closes wrongly.
    static func containerEnd(in text: String, from start: String.Index) -> String.Index? {
        var closers: [Character] = []
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "[":
                    closers.append("]")
                case "{":
                    closers.append("}")
                case "]", "}":
                    guard closers.last == character else { return nil }
                    closers.removeLast()
                    if closers.isEmpty { return text.index(after: index) }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The one distinct `"<name>":{…}` budget object in the stream, decoded as an allowance.
    static func budget(named name: String, in stream: String) -> MistralAllowance? {
        var found: Set<String> = []
        var budgets: [MistralAllowance] = []
        var cursor = stream.startIndex
        while let key = stream.range(of: "\"\(name)\":", range: cursor..<stream.endIndex) {
            cursor = key.upperBound
            guard let start = stream[cursor...].firstIndex(where: { !$0.isWhitespace }),
                  stream[start] == "{",
                  let end = containerEnd(in: stream, from: start)
            else { continue }
            let object = String(stream[start..<end])
            cursor = end
            guard found.insert(object).inserted,
                  let budget = allowance(fromBudgetJSON: Data(object.utf8))
            else { continue }
            budgets.append(budget)
        }
        return budgets.count == 1 ? budgets[0] : nil
    }

    private struct BudgetJSON: Decodable {
        var usagePercentage: Double?
        var initialBudget: Double?
        var currency: String?
        var resetAt: String?

        enum CodingKeys: String, CodingKey {
            case usagePercentage = "usage_percentage"
            case initialBudget = "initial_budget"
            case currency
            case resetAt = "reset_at"
        }
    }

    static func allowance(fromBudgetJSON data: Data) -> MistralAllowance? {
        guard let raw = try? JSONDecoder().decode(BudgetJSON.self, from: data),
              let percent = raw.usagePercentage,
              percent.isFinite,
              percent >= 0
        else { return nil }
        // A server-rendered date can arrive as React's `$D<ISO>` flight-tagged form.
        var resetsAt: Date?
        if let stamp = raw.resetAt {
            let cleaned = stamp.hasPrefix("$D") ? String(stamp.dropFirst(2)) : stamp
            resetsAt = OpenUsageISO8601.date(from: cleaned)
        }
        let currency = raw.currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return MistralAllowance(
            percentUsed: ProviderParse.clampPercent(percent),
            limit: (raw.initialBudget?.isFinite ?? false) && raw.initialBudget.map({ $0 > 0 }) == true
                ? raw.initialBudget
                : nil,
            currency: (currency?.isEmpty ?? true) ? nil : currency,
            resetsAt: resetsAt
        )
    }

    // MARK: - Console tRPC Vibe reply

    private struct VibeReply: Decodable {
        struct Result: Decodable {
            struct Payload: Decodable {
                var json: BudgetJSON?
            }
            var data: Payload?
        }
        var result: Result?
    }

    /// `[{ "result": { "data": { "json": { "usage_percentage", "reset_at" } } } }]`.
    static func allowanceFromVibeReply(_ data: Data) -> MistralAllowance? {
        guard let replies = try? JSONDecoder().decode([VibeReply].self, from: data),
              let json = replies.first?.result?.data?.json
        else { return nil }
        return allowance(fromVibeJSON: json)
    }

    private static func allowance(fromVibeJSON json: BudgetJSON) -> MistralAllowance? {
        guard let percent = json.usagePercentage, percent.isFinite, percent >= 0 else { return nil }
        var resetsAt: Date?
        if let stamp = json.resetAt {
            let cleaned = stamp.hasPrefix("$D") ? String(stamp.dropFirst(2)) : stamp
            resetsAt = OpenUsageISO8601.date(from: cleaned)
        }
        return MistralAllowance(
            percentUsed: ProviderParse.clampPercent(percent),
            limit: (json.initialBudget?.isFinite ?? false) && json.initialBudget.map({ $0 > 0 }) == true
                ? json.initialBudget
                : nil,
            currency: json.currency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().nilIfEmpty,
            resetsAt: resetsAt
        )
    }

    // MARK: - Metric lines

    /// One allowance as a percent meter (Mistral reports the percentage itself); a reported
    /// budget amount and currency enrich the row subtitle at the display edge.
    static func allowanceLine(_ allowance: MistralAllowance, label: String) -> MetricLine {
        .progress(
            label: label,
            used: allowance.percentUsed,
            limit: 100,
            format: .percent,
            resetsAt: allowance.resetsAt,
            periodDurationMs: monthlyPeriodMs
        )
    }
}
