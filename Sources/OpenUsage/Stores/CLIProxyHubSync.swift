import Foundation
import Observation

/// Keeps each connected CLIProxyAPI hub's mirrored accounts in step with its login list, and holds what
/// the hub's row in Accounts shows. A hub is re-read at launch, when Accounts opens, on Refresh, about
/// once an hour, and when the hub tells an account its login is gone.
@MainActor
@Observable
final class CLIProxyHubSync {
    enum Status: Equatable {
        case checking
        case synced(unsupported: Int)
        case failed(String)
    }

    private(set) var statuses: [UUID: Status] = [:]
    @ObservationIgnored private var syncedAt: [UUID: Date] = [:]
    @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let client: CLIProxyHubClient
    @ObservationIgnored private let isEnabled: Bool

    init(accounts: AccountStore, client: CLIProxyHubClient, isEnabled: Bool = CLIProxyHub.isEnabled) {
        self.accounts = accounts
        self.client = client
        self.isEnabled = isEnabled
    }

    func status(of hubID: UUID) -> Status { isEnabled ? statuses[hubID] ?? .checking : .failed(CLIProxyHub.offMessage) }

    /// Connects a hub once its login list answers to the key, so a wrong URL or key saves nothing.
    func connect(url input: String, key: String) async throws {
        guard let url = CLIProxyHub.baseURL(from: input) else {
            throw ProviderError.unavailable("Enter the hub’s address, like https://hub.example.com or http://192.168.1.20:8317.")
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ProviderError.unavailable("Enter the hub’s management key.") }
        if accounts.hubs.contains(where: { $0.url == url }) {
            throw ProviderError.unavailable("The hub at \(CLIProxyHub.host(of: url)) is already connected.")
        }
        let hub = CLIProxyHub(url: url)
        let logins: [HubLogin]
        do {
            logins = try await client.logins(hubID: hub.id, url: url, key: key)
        } catch ProviderError.unreachable(let message, _) {
            guard let plain = await client.plainHTTPAddress(of: url) else { throw ProviderError.unreachable(message) }
            throw ProviderError.unavailable("This hub doesn’t use https. Try \(plain.absoluteString).")
        }
        try Task.checkCancellation()
        guard !accounts.hubs.contains(where: { $0.url == url }) else { return }
        try accounts.addHub(hub, key: key)
        record(logins, for: hub.id)
    }

    /// Saves a new management key only once the hub accepts it, then lets the hub be called again.
    func replaceKey(_ key: String, for hubID: UUID) async throws {
        guard isEnabled else { throw ProviderError.unavailable(CLIProxyHub.offMessage) }
        guard let hub = accounts.hubs.first(where: { $0.id == hubID }) else { return }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let logins = try await client.logins(hubID: UUID(), url: hub.url, key: key)
        try accounts.replaceHubKey(key, for: hubID)
        await client.gate.reopen(hubID)
        record(logins, for: hubID)
    }

    func remove(_ hubID: UUID) {
        accounts.removeHub(hubID)
        guard !accounts.hubs.contains(where: { $0.id == hubID }) else { return }
        statuses[hubID] = nil
        syncedAt[hubID] = nil
        Task { [gate = client.gate] in await gate.reopen(hubID) }
    }

    /// Re-reads every hub not read within `maxAge`.
    func syncDue(maxAge: TimeInterval = RefreshSetting.secondaryReadInterval) async {
        guard isEnabled else { return }
        let due = accounts.hubs.filter { hub in syncedAt[hub.id].map { Date().timeIntervalSince($0) >= maxAge } ?? true }
        await withTaskGroup(of: Void.self) { group in
            for hub in due { group.addTask { await self.sync(hub.id) } }
        }
    }

    private func sync(_ hubID: UUID) async {
        if let running = inFlight[hubID] { return await running.value }
        let task = Task { await self.read(hubID) }
        inFlight[hubID] = task
        defer { inFlight[hubID] = nil }
        await task.value
    }

    /// Re-reads a hub at once: one of its accounts was told by the hub that its login is gone.
    func relist(_ hubID: UUID) async {
        guard isEnabled else { return }
        await sync(hubID)
    }

    /// A listing that found no network path is tried again like a usage read that found none, and the hub
    /// isn't flagged until the last try fails. A failed listing is due again at the next pass.
    private func read(_ hubID: UUID) async {
        var retries = RefreshSetting.offlineRetryDelays[...]
        while let hub = accounts.hubs.first(where: { $0.id == hubID }) {
            syncedAt[hubID] = Date()
            do {
                let key = try accounts.hubKeys.key(for: hubID, at: hub.url)
                return record(try await client.logins(hubID: hubID, url: hub.url, key: key), for: hubID)
            } catch {
                guard accounts.hubs.contains(where: { $0.id == hubID }) else { return }
                guard case ProviderError.unreachable(_, offline: true) = error, let delay = retries.popFirst() else {
                    syncedAt[hubID] = nil
                    statuses[hubID] = .failed(error.localizedDescription)
                    return
                }
                AppLog.warn(LogTag.auth("cliproxy"), "\(CLIProxyHub.host(of: hub.url)) login list offline. Retrying in \(Int(delay))s.")
                guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            }
        }
    }

    /// A failed Keychain write leaves the hub unread, so the next sync tries again.
    private func record(_ logins: [HubLogin], for hubID: UUID) {
        guard accounts.hubs.contains(where: { $0.id == hubID }) else { return }
        do {
            try accounts.mirror(logins, from: hubID)
        } catch {
            syncedAt[hubID] = nil
            statuses[hubID] = .failed(error.localizedDescription)
            return
        }
        syncedAt[hubID] = Date()
        statuses[hubID] = .synced(unsupported: logins.count(where: \.isUnsupported))
    }
}
