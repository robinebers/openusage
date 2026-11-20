import Foundation

extension AccountProviderRuntime {
    func refreshPlivo(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let key) = credential else { throw unreadableCredential }
        guard let credentials = PlivoCredentials(key: key) else {
            throw ProviderError.keyRejected("Plivo needs the Auth ID and Auth Token as AUTH_ID:AUTH_TOKEN.")
        }
        let response = try await PlivoUsageClient(http: http).fetchAccount(credentials)
        try ProviderError.requireSuccess(response, kind: .plivo)
        return try PlivoUsageMapper.map(response.body)
    }
}
