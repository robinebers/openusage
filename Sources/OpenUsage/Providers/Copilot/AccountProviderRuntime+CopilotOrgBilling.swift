import Foundation

extension AccountProviderRuntime {
    func copilotOrgLines(after usage: HTTPResponse, adminToken: String) async -> [MetricLine] {
        guard copilotOrgRead.isDue(at: now()) else { return copilotOrgRead.value ?? [] }
        var lines: [MetricLine] = []
        for org in CopilotOrgBillingMapper.orgLogins(usage) {
            guard let response = try? await CopilotUsageClient(http: http).fetchOrgCredits(org: org, adminToken: adminToken),
                  (200..<300).contains(response.statusCode)
            else { continue }
            lines = CopilotOrgBillingMapper.usageLines(response)
            if !lines.isEmpty { break }
        }
        copilotOrgRead.record(lines, at: now())
        return lines
    }

    /// Stores the admin token with the account's sign-in only once it reads the first organization's
    /// billing, so a token GitHub refuses is never saved; `nil` removes it.
    func saveCopilotAdminToken(_ adminToken: String?) async throws {
        guard case .oauth(var tokens) = try await loadCredential() else { throw ProviderError.invalidResponse }
        if let adminToken {
            let client = CopilotUsageClient(http: http)
            let usage = try await client.fetchUsage(token: tokens.accessToken)
            try ProviderError.requireSuccess(usage, kind: .copilot)
            guard let org = CopilotOrgBillingMapper.orgLogins(usage).first else {
                throw ProviderError.unavailable("Copilot lists no organization for this account, so there is no org billing to read.")
            }
            let billing = try await client.fetchOrgCredits(org: org, adminToken: adminToken)
            if ProviderError.isAuthFailure(billing) {
                throw ProviderError.unavailable(
                    "GitHub rejected the admin token for \(org). Use one from an owner or billing manager with Administration read access."
                )
            }
            guard (200..<300).contains(billing.statusCode) else { throw ProviderError.failed(billing) }
        }
        tokens.extras[OAuthTokens.adminTokenKey] = adminToken
        try await replaceCredential(.oauth(tokens))
    }
}
