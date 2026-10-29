import Foundation
import Observation

/// Keeps each connected CLIProxyAPI hub's mirrored accounts in step with its login list, and holds what
/// the hub's row in Accounts shows. A hub is re-read at launch, when Accounts opens, about once an hour,
/// and soon after a call finds one of its logins gone.
@MainActor
@Observable
final class CLIProxyHubSync {
    enum Status: Equatable {
        case checking
        case synced(unsupported: Int, alreadyAdded: Int)
        case failed(String)
    }

    private(set) var statuses: [UUID: Status] = [:]
    @ObservationIgnored private var syncedAt: [UUID: Date] = [:]
    @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var claudeIdentities: [String: String] = [:]
    @ObservationIgnored private let accounts: AccountStore
    @ObservationIgnored private let client: CLIProxyHubClient
    @ObservationIgnored private let now: () -> Date

    init(accounts: AccountStore, client: CLIProxyHubClient, now: @escaping () -> Date = Date.init) {
        self.accounts = accounts
        self.client = client
        self.now = now
    }

    func status(of hubID: UUID) -> Status { statuses[hubID] ?? .checking }

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
        await record(logins, for: hub)
    }

    /// Saves a new management key only once the hub accepts it, then lets the hub be called again.
    func replaceKey(_ key: String, for hubID: UUID) async throws {
        guard let hub = accounts.hubs.first(where: { $0.id == hubID }) else { return }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let logins = try await client.logins(hubID: UUID(), url: hub.url, key: key)
        try accounts.replaceHubKey(key, for: hubID)
        await client.gate.reopen(hubID)
        await record(logins, for: hub)
    }

    func remove(_ hubID: UUID) {
        accounts.removeHub(hubID)
        guard !accounts.hubs.contains(where: { $0.id == hubID }) else { return }
        statuses[hubID] = nil
        syncedAt[hubID] = nil
        Task { [gate = client.gate] in await gate.reopen(hubID) }
    }

    /// Re-reads every hub not read within `maxAge`, and every hub a call asked to have re-read.
    func syncDue(maxAge: TimeInterval = RefreshSetting.secondaryReadInterval) async {
        let requested = await client.gate.takeSyncRequests()
        let due = accounts.hubs.filter { hub in
            requested.contains(hub.id) || syncedAt[hub.id].map { now().timeIntervalSince($0) >= maxAge } ?? true
        }
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
            await record(try await client.logins(hubID: hubID, url: hub.url, key: key), for: hub)
        } catch {
            guard accounts.hubs.contains(where: { $0.id == hubID }) else { return }
            statuses[hubID] = .failed(error.localizedDescription)
        }
    }

    private func record(_ logins: [HubLogin], for hub: CLIProxyHub) async {
        let identified = await identifyingClaude(logins, on: hub)
        guard accounts.hubs.contains(where: { $0.id == hub.id }) else { return }
        let alreadyAdded = accounts.mirror(identified, from: hub.id)
        syncedAt[hub.id] = now()
        statuses[hub.id] = .synced(unsupported: logins.count { $0.kind == nil }, alreadyAdded: alreadyAdded)
    }

    /// The listing with each new Claude login's identity, read once through the hub, while a Claude
    /// account signed in directly could be the same login. The listing has no Claude identity, and an
    /// email can belong to two Claude organizations. A login whose identity can't be read is left out
    /// until the next read, so it is never added twice.
    private func identifyingClaude(_ logins: [HubLogin], on hub: CLIProxyHub) async -> [HubLogin] {
        guard accounts.accounts.contains(where: { $0.kind == .claude && $0.hub == nil }) else { return logins }
        let mirrored = Set(accounts.accounts(onHub: hub.id).compactMap { $0.hub?.loginID })
        var identified: [HubLogin] = []
        for var login in logins {
            if login.kind == .claude, login.identity == nil, !mirrored.contains(login.id) {
                let key = "\(hub.id)/\(login.id)/\(login.authIndex)"
                if claudeIdentities[key] == nil {
                    let tunnel = HubTunnel(link: HubLink(hub: hub, login: login), kind: .claude, vault: accounts.credentialVault, client: client)
                    do {
                        let response = try await ClaudeUsageClient(httpClient: tunnel).fetchProfile(accessToken: CLIProxyHubClient.tokenPlaceholder)
                        claudeIdentities[key] = try ClaudeUsageClient.decodeProfile(response).identity
                    } catch {
                        AppLog.warn(LogTag.auth("cliproxy"), "\(hub.host) Claude login profile read failed; adding it after the next read: \(error.localizedDescription)")
                        continue
                    }
                }
                login.identity = claudeIdentities[key]
            }
            identified.append(login)
        }
        return identified
    }
}
