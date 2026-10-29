import Foundation

extension AccountProviderRuntime {
    func cursorUsage(_ usage: [String: Any], client: CursorUsageClient, accessToken: String) async throws -> ProviderUsage {
        var summary: [String: Any]?
        var summaryWasRead = false
        func readSummary() async -> [String: Any]? {
            if !summaryWasRead {
                summaryWasRead = true
                summary = await optionalJSON("usage-summary") { try await client.fetchUsageSummary(accessToken: accessToken) }
            }
            return summary
        }

        if planRead.isDue(at: now()) {
            let fresh = await optionalJSON("plan") { try await client.fetchPlan(accessToken: accessToken) }
                .flatMap { ($0["planInfo"] as? [String: Any])?["planName"] as? String }
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            planRead.record(fresh, at: now())
        }
        if cursorMembershipRead.isDue(at: now()) {
            cursorMembershipRead.record(CursorUsageMapper.membershipType(in: await readSummary()), at: now())
        }
        let planName = planRead.value
        let membership = cursorMembershipRead.value
        let isOrgSeat = membership.map(CursorUsageMapper.orgMembershipTypes.contains) ?? false
        let displayPlanName = CursorUsageMapper.resolvedPlanName(planInfoName: planName, membershipType: membership)
        let facts = CursorPlanUsageFacts(usage: usage)
        let fallback = CursorUsageMapper.shouldUseRequestBasedFallback(facts: facts, planName: isOrgSeat ? membership : planName)

        var mapped: ProviderUsage
        if fallback.shouldFallback {
            mapped = try CursorUsageSummaryMapper.map(
                summary: await readSummary(),
                requestUsage: await optionalJSON("request-based usage") { try await client.fetchRequestBasedUsage(accessToken: accessToken) },
                planName: displayPlanName,
                unavailableMessage: fallback.message
            )
        } else if facts.shouldTryGenericRequestFallback,
                  let requestUsage = await optionalJSON("request-based usage", { try await client.fetchRequestBasedUsage(accessToken: accessToken) }),
                  let requestBased = try? CursorUsageSummaryMapper.map(
                      summary: nil, requestUsage: requestUsage, planName: displayPlanName, unavailableMessage: ""
                  ) {
            mapped = requestBased
        } else {
            let stripe = await optionalJSON("prepaid-balance") { try await client.fetchStripeBalance(accessToken: accessToken) }
            mapped = try CursorUsageMapper.mapUsage(
                usage: usage,
                planName: planName,
                creditGrants: await optionalJSON("credit-grants") { try await client.fetchCredits(accessToken: accessToken) },
                stripeBalanceCents: CursorUsageMapper.stripeBalanceCents(from: stripe)
            )
            mapped.plan = CursorUsageMapper.resolvedPlanLabel(planInfoName: planName, membershipType: membership)
            let needsOnDemand = !mapped.lines.contains { $0.label == "On-demand" }
            if isOrgSeat ? needsOnDemand : facts.isTeamByShape,
               let summary = await readSummary(),
               CursorUsageSummaryMapper.hasUsableSummaryPayload(summary) {
                CursorUsageSummaryMapper.appendMissingOnDemand(from: summary, to: &mapped.lines)
                mapped.plan = CursorUsageMapper.resolvedPlanLabel(
                    planInfoName: planName,
                    membershipType: CursorUsageMapper.membershipType(in: summary) ?? membership
                ) ?? mapped.plan
            }
        }

        if let grokBot = await optionalJSON("Grok Bot usage", { try await client.fetchGrokBotUsage(accessToken: accessToken) }),
           let line = CursorUsageMapper.mapGrokBotUsage(grokBot) {
            mapped.lines.append(line)
        }
        return mapped
    }

    private func optionalJSON(_ label: String, _ request: () async throws -> HTTPResponse?) async -> [String: Any]? {
        let tag = LogTag.plugin("cursor")
        let response: HTTPResponse?
        do {
            response = try await request()
        } catch {
            AppLog.warn(tag, "\(account.cardID) optional \(label) request failed: \(error.localizedDescription)")
            return nil
        }
        guard let response else {
            AppLog.warn(tag, "\(account.cardID) optional \(label) request could not be prepared from the current session")
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(tag, "\(account.cardID) optional \(label) request returned HTTP \(response.statusCode)")
            return nil
        }
        guard let body = ProviderParse.jsonObject(response.body) else {
            AppLog.warn(tag, "\(account.cardID) optional \(label) response was not a JSON object")
            return nil
        }
        return body
    }
}
