import Foundation
import Security

/// A hub's management key and the address the user connected the hub at. The key is sent only to that
/// address, so a hub address rewritten in preferences can't redirect it.
struct HubKey: Codable, Equatable, Sendable {
    let key: String
    let url: URL
}

/// Management keys, in a Keychain service of their own: a hub id can never load or delete an account's sign-in.
protocol HubKeyVault: Sendable {
    func load(_ hubID: UUID) throws -> HubKey?
    func save(_ key: HubKey, for hubID: UUID) throws
    func delete(_ hubID: UUID) throws
}

extension HubKeyVault {
    /// The hub's management key, only for the address it was saved for.
    func key(for hubID: UUID, at url: URL) throws -> String {
        let host = CLIProxyHub.host(of: url)
        guard let stored = try load(hubID) else {
            AppLog.error(LogTag.auth("cliproxy"), "\(host) has no stored management key")
            throw ProviderError.unavailable("The management key for the CLIProxyAPI hub at \(host) is missing. Replace it in Accounts.")
        }
        guard stored.url == url else {
            AppLog.error(LogTag.auth("cliproxy"), "\(host) is not the address its management key was saved for; not sending it")
            throw ProviderError.unavailable("The CLIProxyAPI hub at \(host) isn’t the address its management key was saved for. Remove the hub and connect it again.")
        }
        return stored.key
    }
}

struct KeychainHubKeyVault: HubKeyVault {
    static let service = "com.robinebers.openusage.cliproxy-hubs"
    private let items = KeychainItems(service: service)

    func load(_ hubID: UUID) throws -> HubKey? {
        try items.load(hubID).map { try JSONDecoder().decode(HubKey.self, from: $0) }
    }

    func save(_ key: HubKey, for hubID: UUID) throws {
        try items.save(JSONEncoder().encode(key), for: hubID)
    }

    func delete(_ hubID: UUID) throws {
        try items.delete(hubID)
    }
}
