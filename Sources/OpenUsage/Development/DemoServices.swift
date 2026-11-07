#if OPENUSAGE_DEVELOPMENT
import Foundation
import os

/// Demo metadata can be renamed or removed without reading or writing a Keychain item.
struct DemoCredentialVault: CredentialVault {
    private let credentials = OSAllocatedUnfairLock(initialState: [UUID: AccountCredential]())

    func load(_ id: UUID) throws -> AccountCredential? { credentials.withLock { $0[id] } }
    func save(_ credential: AccountCredential, for id: UUID) throws { credentials.withLock { $0[id] = credential } }
    func update(_ credential: AccountCredential, for id: UUID) throws {
        try credentials.withLock {
            guard $0[id] != nil else { throw CredentialVaultError.missingCredential }
            $0[id] = credential
        }
    }
    func delete(_ id: UUID) throws { credentials.withLock { $0[id] = nil } }
}

struct DemoHubKeyVault: HubKeyVault {
    private let keys = OSAllocatedUnfairLock(initialState: [UUID: HubKey]())

    func load(_ hubID: UUID) throws -> HubKey? { keys.withLock { $0[hubID] } }
    func save(_ key: HubKey, for hubID: UUID) throws { keys.withLock { $0[hubID] = key } }
    func delete(_ hubID: UUID) throws { keys.withLock { $0[hubID] = nil } }
}

/// A second boundary behind the disabled demo controls. This client never constructs a URLSession.
struct DemoHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        AppLog.error(.http, "Blocked a provider request while Sample Data is on")
        throw ProviderError.unavailable("Provider connections are unavailable while Sample Data is on.")
    }
}

@MainActor
final class DemoTelemetrySink: TelemetrySink {
    func capture(_ event: String, _ properties: [String: Any]) {}
    func flush() {}
}
#endif
