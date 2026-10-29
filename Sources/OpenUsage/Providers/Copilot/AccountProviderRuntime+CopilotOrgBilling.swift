import Foundation

extension AccountProviderRuntime {
    func copilotOrgLines(after usage: HTTPResponse, adminToken: String) async -> [MetricLine] {
        if copilotOrgRead.isDue(at: now()) {
            let billing = await copilotOrgBilling(orgs: CopilotOrgBillingMapper.orgLogins(usage), adminToken: adminToken)
            copilotOrgRead.record(billing.map(CopilotOrgBillingMapper.usageLines) ?? [], at: now())
        }
        return copilotOrgRead.value ?? []
    }

    /// Stores the admin token with the account's sign-in only once it reads one of the account's
    /// organizations' billing, so a token GitHub refuses is never saved; `nil` removes it.
    func saveCopilotAdminToken(_ adminToken: String?) async throws {
        guard case .oauth(var tokens) = try await loadCredential() else { throw ProviderError.invalidResponse }
        if let adminToken {
            let usage = try await CopilotUsageClient(http: http).fetchUsage(token: tokens.accessToken)
            try ProviderError.requireSuccess(usage, kind: .copilot)
            let orgs = CopilotOrgBillingMapper.orgLogins(usage)
            guard !orgs.isEmpty else { throw ProviderError.unavailable("Copilot lists no organization for this account, so there is no org billing to read.") }
            guard await copilotOrgBilling(orgs: orgs, adminToken: adminToken) != nil else {
                throw ProviderError.unavailable(
                    "GitHub did not let this token read any of your organizations' billing. Use a token from an organization owner or billing manager with Administration read access."
                )
            }
        }
        tokens.extras[OAuthTokens.adminTokenKey] = adminToken
        try await replaceCredential(.oauth(tokens))
    }

    /// The billing of the first organization the token can read: a fine-grained token reads only the
    /// one organization it was made for.
    private func copilotOrgBilling(orgs: [String], adminToken: String) async -> HTTPResponse? {
        for org in orgs {
            if let response = try? await CopilotUsageClient(http: http).fetchOrgCredits(org: org, adminToken: adminToken),
               (200..<300).contains(response.statusCode) { return response }
        }
        return nil
    }
}
