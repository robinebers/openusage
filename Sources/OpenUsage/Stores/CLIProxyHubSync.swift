import Foundation
import Observation

/// Keeps each connected CLIProxyAPI hub's mirrored accounts in step with its login list, and holds what
/// the hub's row in Accounts shows. A hub is re-read at launch, when Accounts opens, and about once an hour.
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
    @ObservationIgnored private let now: () -> Date

    init(
        accounts: AccountStore, client: CLIProxyHubClient, isEnabled: Bool = CLIProxyHub.isEnabled, now: @escaping () -> Date = Date.init
    ) {
        self.accounts = accounts
        self.client = client
        self.isEnabled = isEnabled
        self.now = now
    }

    func status(of hubID: UUID) -> Status { isEnabled ? statuses[hubID] ?? .checking : .failed(CLIProxyHub.offMessage) }

    /// Connects a hub once its login list answers to the key, so a wrong URL or key saves nothing.
    func connect(url input: String, key: String) async throws {
        guard let url = CLIProxyHub.baseURL(from: input) else {
            throw ProviderError.unavailable("Enter the hub’s address, like http://192.168.1.20:8317.")
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ProviderError.unavailable("Enter the hub’s management key.") }
        if accounts.hubs.contains(where: { $0.url == url }) {
            throw ProviderError.unavailable("The hub at \(CLIProxyHub.host(of: url)) is already connected.")
        }
        let hub = CLIProxyHub(url: url)
        let logins = try await client.logins(hubID: hub.id, url: url, key: key)
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
        let due = accounts.hubs.filter { hub in syncedAt[hub.id].map { now().timeIntervalSince($0) >= maxAge } ?? true }
        await withTaskGroup(of: Void.self) { group in
            for hub in due { group.addTask { await self.sync(hub.id) } }
        }
    }

    func sync(_ hubID: UUID) async {
        if let running = inFlight[hubID] { return await running.value }
        let task = Task { await self.read(hubID) }
        inFlight[hubID] = task
        defer { inFlight[hubID] = nil }
        await task.value
    }

    private func read(_ hubID: UUID) async {
        guard let hub = accounts.hubs.first(where: { $0.id == hubID }) else { return }
        syncedAt[hubID] = now()
        do {
            guard case .apiKey(let key) = try accounts.credential(for: hubID) else {
                throw ProviderError.unavailable("The management key for this hub is missing. Replace it.")
            }
            record(try await client.logins(hubID: hubID, url: hub.url, key: key), for: hubID)
        } catch {
            guard accounts.hubs.contains(where: { $0.id == hubID }) else { return }
            statuses[hubID] = .failed(error.localizedDescription)
        }
    }

    private func record(_ logins: [HubLogin], for hubID: UUID) {
        guard accounts.hubs.contains(where: { $0.id == hubID }) else { return }
        accounts.mirror(logins, from: hubID)
        syncedAt[hubID] = now()
        statuses[hubID] = .synced(unsupported: logins.count { $0.kind == nil })
    }
}
