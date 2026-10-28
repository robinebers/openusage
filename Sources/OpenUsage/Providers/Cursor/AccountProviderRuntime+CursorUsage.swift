import Foundation

extension AccountProviderRuntime {
    /// Maps a `GetCurrentPeriodUsage` body to Cursor's metrics. Request-based Team and Enterprise seats read the REST usage endpoints instead. Everyone
    /// else maps the primary body with credits, and team-shaped seats pick up Extra Usage and the billing
    /// membership from usage-summary. Grok Bot has its own allowance and is added in every case. Every
    /// request but the primary one is optional: a failure leaves its metric out. The plan name is read
    /// hourly (`planRead`).
    func cursorUsage(_ usage: [String: Any], client: CursorUsageClient, accessToken: String) async throws -> ProviderUsage {
        if planRead.isDue(at: now()) {
            let fresh = await Self.optionalJSON { try await client.fetchPlan(accessToken: accessToken) }
                .flatMap { ($0["planInfo"] as? [String: Any])?["planName"] as? String }
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            planRead.record(fresh, at: now())
        }
        let planName = planRead.value
        let facts = CursorPlanUsageFacts(usage: usage)
        let fallback = CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage, planName: planName, planInfoUnavailable: planName == nil
        )

        var mapped: ProviderUsage
        if fallback.shouldFallback {
            mapped = try CursorUsageSummaryMapper.map(
                summary: await Self.optionalJSON { try await client.fetchUsageSummary(accessToken: accessToken) },
                requestUsage: await Self.optionalJSON { try await client.fetchRequestBasedUsage(accessToken: accessToken) },
                planName: planName,
                unavailableMessage: fallback.message
            )
        } else if facts.shouldTryGenericRequestFallback,
                  let requestUsage = await Self.optionalJSON({ try await client.fetchRequestBasedUsage(accessToken: accessToken) }),
                  let requestBased = try? CursorUsageMapper.mapRequestBasedUsage(
                      requestUsage, planName: planName, unavailableMessage: ""
                  ) {
            mapped = requestBased
        } else {
            let stripe = await Self.optionalJSON { try await client.fetchStripeBalance(accessToken: accessToken) }
            mapped = try CursorUsageMapper.mapUsage(
                usage: usage,
                planName: planName,
                creditGrants: await Self.optionalJSON { try await client.fetchCredits(accessToken: accessToken) },
                stripeBalanceCents: CursorUsageMapper.stripeBalanceCents(from: stripe)
            )
            if facts.isTeamByShape,
               let summary = await Self.optionalJSON({ try await client.fetchUsageSummary(accessToken: accessToken) }),
               CursorUsageSummaryMapper.hasUsableSummaryPayload(summary) {
                CursorUsageSummaryMapper.appendMissingOnDemand(from: summary, to: &mapped.lines)
                mapped.plan = CursorUsageMapper.resolvedPlanLabel(
                    planInfoName: planName,
                    membershipType: summary["membershipType"] as? String
                ) ?? mapped.plan
            }
        }

        if let grokBot = await Self.optionalJSON({ try await client.fetchGrokBotUsage(accessToken: accessToken) }),
           let line = CursorUsageMapper.mapGrokBotUsage(grokBot) {
            mapped.lines.append(line)
        }
        return mapped
    }

    private static func optionalJSON(_ request: () async throws -> HTTPResponse?) async -> [String: Any]? {
        guard let response = try? await request(), (200..<300).contains(response.statusCode) else { return nil }
        return ProviderParse.jsonObject(response.body)
    }
}
