import Foundation

extension AccountProviderRuntime {
    /// A long-lived token from `claude setup-token` holds `user:inference` only, so Anthropic refuses it at
    /// `/api/oauth/usage` and `/api/oauth/profile`. Anthropic reports the same windows as
    /// `anthropic-ratelimit-unified-*` headers on a model request, so each refresh sends the smallest one
    /// there is and reads them. An account at its limit answers 429 with the headers still on it, so the
    /// request skips the usage endpoint's 429 window.
    ///
    /// Anthropic sends Fable's weekly window only on a request to Fable, so that is the model asked. A
    /// plan without Fable, or a retired model id, answers without the headers and the smallest model is
    /// asked instead.
    func refreshClaudeToken(_ token: String) async throws -> ProviderUsage {
        let client = ClaudeUsageClient(httpClient: http)
        var response = try await client.fetchLimitHeaders(token: token, model: ClaudeUsageClient.fableProbeModel)
        if !ClaudeUsageMapper.hasLimitHeaders(response), response.statusCode != 401, response.statusCode != 403 {
            response = try await client.fetchLimitHeaders(token: token, model: ClaudeUsageClient.limitProbeModel)
        }
        return ProviderUsage(plan: nil, lines: try ClaudeUsageMapper.mapLimitHeaders(response), lineTitles: [:])
    }
}

extension ClaudeUsageClient {
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The model whose answer carries Fable's weekly window beside the account's own.
    static let fableProbeModel = "claude-fable-5-2"
    /// The cheapest model a subscription token may call. Anthropic retires model ids, so a 404 here means
    /// this needs the current small model.
    static let limitProbeModel = "claude-haiku-5-5"

    /// One output token: `count_tokens` and `/v1/models` cost nothing but come back without the limit
    /// headers. Anthropic accepts a subscription token here only with Claude Code's system prompt.
    func fetchLimitHeaders(token: String, model: String) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "system": "You are Claude Code, Anthropic's official CLI for Claude.",
            "messages": [["role": "user", "content": "hi"]]
        ])
        return try await httpClient.send(HTTPRequest(
            method: "POST",
            url: Self.messagesURL,
            headers: [
                "Authorization": "Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-version": "2023-06-01",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-cli/\(Self.claudeCodeVersion) (external, cli)"
            ],
            body: body,
            timeout: 20
        ))
    }
}

extension ClaudeUsageMapper {
    /// `anthropic-ratelimit-unified-<window>-utilization` is a fraction of the window, and `-reset` is epoch
    /// seconds. Anthropic sends only the windows the account has, so a missing one adds no line. `7d_oi` is
    /// `seven_day_overage_included`, Anthropic's name for Fable's weekly limit (see `ClaudeResetGrantStatus`).
    static func mapLimitHeaders(_ response: HTTPResponse) throws -> [MetricLine] {
        var lines: [MetricLine] = []
        appendLimitHeader(response, window: "5h", label: "Session", periodMs: MetricPeriod.sessionMs, to: &lines)
        appendLimitHeader(response, window: "7d", label: "Weekly", periodMs: MetricPeriod.weekMs, to: &lines)
        appendLimitHeader(response, window: "7d_oi", label: "Fable", periodMs: MetricPeriod.weekMs, to: &lines)
        guard lines.isEmpty else { return lines }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ProviderError.keyRejected("Claude rejected the token.")
        }
        guard (200..<300).contains(response.statusCode) else { throw ProviderError.failed(response) }
        throw ProviderError.unavailable("Claude reported no usage limits for this token.")
    }

    static func hasLimitHeaders(_ response: HTTPResponse) -> Bool {
        ["5h", "7d", "7d_oi"].contains { response.header("anthropic-ratelimit-unified-\($0)-utilization") != nil }
    }

    private static func appendLimitHeader(
        _ response: HTTPResponse, window: String, label: String, periodMs: Int, to lines: inout [MetricLine]
    ) {
        let prefix = "anthropic-ratelimit-unified-\(window)"
        guard let text = response.header("\(prefix)-utilization")?.trimmingCharacters(in: .whitespaces),
              let fraction = Double(text), fraction.isFinite
        else { return }
        let reset = response.header("\(prefix)-reset")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .map { Date(timeIntervalSince1970: $0) }
        // Rounded to a hundredth of a percent, so 0.07 reads 7 and not 7.000000000000001.
        let percent = (fraction * 10_000).rounded() / 100
        lines.append(.percent(label, ProviderParse.clampPercent(percent), resetsAt: reset, periodMs: periodMs))
    }
}
