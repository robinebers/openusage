import CryptoKit
import Foundation
import Network
import Observation

/// Owns Bonjour discovery, explicit pairing approval, authenticated encrypted snapshot fetches, and
/// paired-device persistence. Networking is opt-in and stops completely when the Settings toggle is off.
@MainActor
@Observable
final class LANSyncStore {
    static let enabledKey = "lanSync.enabled"
    private static let deviceIDKey = "lanSync.deviceID"
    private static let pairedDevicesKey = "lanSync.pairedDevices.v1"

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    private(set) var nearbyDevices: [LANNearbyDevice] = []
    private(set) var pairedDevices: [LANPairedDevice]
    private(set) var incomingPairRequests: [LANIncomingPairRequest] = []
    private(set) var outgoingPairing: LANOutgoingPairing?
    private(set) var peerStates: [String: LANPeerSyncState] = [:]
    /// True while a pairing handshake or approval prompt is on screen. The panel's outside-click
    /// policy keeps the popover open in this state so a click on a system dialog (or a stray click
    /// while comparing codes) doesn't tear the pairing UI down mid-flow.
    var isPairingActive: Bool { outgoingPairing != nil || !incomingPairRequests.isEmpty }
    private(set) var serviceError: String?

    let deviceID: String
    let deviceName: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secretStore: any LANSyncSecretStoring
    @ObservationIgnored private let localSnapshots: @MainActor () -> [String: ProviderSnapshot]
    @ObservationIgnored private let applyRemoteSnapshots: @MainActor (String, [String: ProviderSnapshot]) -> Void
    @ObservationIgnored private let removeRemoteSnapshots: @MainActor (String) -> Void
    @ObservationIgnored private let queue = DispatchQueue(label: "openusage.lan-sync")
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private(set) var testingListenerEndpoint: NWEndpoint?
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var discoveredNames: [String: String] = [:]
    @ObservationIgnored private var approvalContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var runningTasks: [UUID: Task<Void, Never>] = [:]

    init(
        defaults: UserDefaults = .standard,
        secretStore: any LANSyncSecretStoring = KeychainLANSyncSecretStore(),
        localSnapshots: @escaping @MainActor () -> [String: ProviderSnapshot],
        applyRemoteSnapshots: @escaping @MainActor (String, [String: ProviderSnapshot]) -> Void,
        removeRemoteSnapshots: @escaping @MainActor (String) -> Void
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
        self.localSnapshots = localSnapshots
        self.applyRemoteSnapshots = applyRemoteSnapshots
        self.removeRemoteSnapshots = removeRemoteSnapshots
        if let existing = defaults.string(forKey: Self.deviceIDKey) {
            self.deviceID = existing
        } else {
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: Self.deviceIDKey)
            self.deviceID = id
        }
        self.deviceName = Host.current().localizedName?.nilIfEmpty ?? "Mac"
        self.pairedDevices = Self.loadPairedDevices(defaults: defaults)
        self.enabled = defaults.bool(forKey: Self.enabledKey)
    }

    deinit {
        listener?.cancel()
        browser?.cancel()
        runningTasks.values.forEach { $0.cancel() }
    }

    func start() {
        guard enabled, listener == nil, browser == nil else { return }
        serviceError = nil
        startListener()
        startBrowser()
    }

    func pair(with deviceID: String) {
        guard enabled, let endpoint = endpoints[deviceID],
              let nearby = nearbyDevices.first(where: { $0.id == deviceID }) else { return }
        beginPairing(deviceID: deviceID, name: nearby.name, endpoint: endpoint)
    }

    /// Direct-endpoint seams for the opt-in integration test. Production always reaches these operations
    /// through Bonjour discovery; the seams keep authenticated TCP testable on hosts that block mDNS.
    func pairForTesting(deviceID: String, name: String, endpoint: NWEndpoint) {
        beginPairing(deviceID: deviceID, name: name, endpoint: endpoint)
    }

    func syncForTesting(device: LANPairedDevice, endpoint: NWEndpoint) async {
        await sync(device: device, endpoint: endpoint)
    }

    private func beginPairing(deviceID: String, name: String, endpoint: NWEndpoint) {
        outgoingPairing = .connecting(deviceID: deviceID, name: name)
        launchTask { [weak self] in
            await self?.performPairing(deviceID: deviceID, name: name, endpoint: endpoint)
        }
    }

    func approvePairing(_ requestID: UUID) {
        finishApproval(requestID, approved: true)
    }

    func denyPairing(_ requestID: UUID) {
        finishApproval(requestID, approved: false)
    }

    func dismissPairingStatus() { outgoingPairing = nil }

    func forget(_ deviceID: String) {
        // Best-effort courtesy: while this Mac still holds the shared secret, tell the peer (if
        // currently reachable) to drop its side of the pairing too, so it doesn't keep a stale
        // "Connected" entry that only errors on the next sync. Local cleanup never waits on this.
        if let endpoint = endpoints[deviceID], let secret = try? secretStore.secret(for: deviceID) {
            launchTask { [weak self] in
                await self?.sendUnpair(deviceID: deviceID, endpoint: endpoint, secret: secret)
            }
        }
        pairedDevices.removeAll { $0.id == deviceID }
        persistPairedDevices()
        do {
            try secretStore.deleteSecret(for: deviceID)
        } catch {
            serviceError = "Couldn't remove the saved connection key: \(error.localizedDescription)"
            AppLog.error(.localAPI, "LAN sync key deletion failed: \(error.localizedDescription)")
        }
        removeRemoteSnapshots(deviceID)
        peerStates[deviceID] = nil
        rebuildNearbyDevices()
    }

    /// Fetch each currently discoverable approved Mac in parallel. Called after every normal/manual
    /// provider refresh and once immediately after pairing succeeds.
    func refreshAvailablePeers() async {
        guard enabled else { return }
        let targets = pairedDevices.compactMap { device -> (LANPairedDevice, NWEndpoint)? in
            endpoints[device.id].map { (device, $0) }
        }
        for (device, endpoint) in targets {
            launchTask { [weak self] in
                await self?.sync(device: device, endpoint: endpoint)
            }
        }
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(
                name: deviceName,
                type: LANSyncProtocol.serviceType,
                txtRecord: NWTXTRecord([
                    "id": deviceID,
                    "name": deviceName,
                    "v": String(LANSyncProtocol.version)
                ])
            )
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerStateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            serviceError = "Couldn't share usage on the local network: \(error.localizedDescription)"
            AppLog.error(.localAPI, "LAN sync listener failed: \(error.localizedDescription)")
        }
    }

    private func startBrowser() {
        // .bonjourWithTXTRecord is required: a plain .bonjour browse returns results with no metadata,
        // so the id/version filter below would silently drop every discovered Mac.
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: LANSyncProtocol.serviceType, domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.browserStateChanged(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.browserResultsChanged(results) }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func stop() {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        testingListenerEndpoint = nil
        endpoints.removeAll()
        discoveredNames.removeAll()
        nearbyDevices.removeAll()
        outgoingPairing = nil
        approvalContinuations.values.forEach { $0.resume(returning: false) }
        approvalContinuations.removeAll()
        incomingPairRequests.removeAll()
        runningTasks.values.forEach { $0.cancel() }
        runningTasks.removeAll()
        for device in pairedDevices { removeRemoteSnapshots(device.id) }
        peerStates = pairedDevices.reduce(into: [:]) { $0[$1.id] = LANPeerSyncState() }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            serviceError = "Couldn't share usage on the local network: \(error.localizedDescription)"
            AppLog.error(.localAPI, "LAN sync listener failed: \(error.localizedDescription)")
        case .ready:
            if let port = listener?.port {
                testingListenerEndpoint = .hostPort(host: "127.0.0.1", port: port)
            }
            AppLog.info(.localAPI, "LAN sync advertising as \(deviceName)")
        default: break
        }
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
        if case .failed(let error) = state {
            serviceError = "Couldn't find Macs on the local network: \(error.localizedDescription)"
            AppLog.error(.localAPI, "LAN sync browser failed: \(error.localizedDescription)")
        }
    }

    private func browserResultsChanged(_ results: Set<NWBrowser.Result>) {
        var found: [String: (name: String, endpoint: NWEndpoint)] = [:]
        for result in results {
            guard case .bonjour(let record) = result.metadata,
                  let id = record["id"], id != deviceID,
                  record["v"] == String(LANSyncProtocol.version) else { continue }
            found[id] = (record["name"]?.nilIfEmpty ?? serviceName(from: result.endpoint), result.endpoint)
        }
        endpoints = found.mapValues(\.endpoint)
        discoveredNames = found.mapValues(\.name)
        let availableIDs = Set(found.keys)
        for device in pairedDevices {
            var state = peerStates[device.id] ?? LANPeerSyncState()
            state.isAvailable = availableIDs.contains(device.id)
            peerStates[device.id] = state
            if !state.isAvailable { removeRemoteSnapshots(device.id) }
        }
        rebuildNearbyDevices(found: found)
    }

    private func rebuildNearbyDevices(found: [String: (name: String, endpoint: NWEndpoint)]? = nil) {
        let pairedIDs = Set(pairedDevices.map(\.id))
        if let found { discoveredNames = found.mapValues(\.name) }
        nearbyDevices = endpoints.map { id, _ in
            LANNearbyDevice(id: id, name: discoveredNames[id] ?? "Mac", isPaired: pairedIDs.contains(id))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func accept(_ connection: NWConnection) {
        launchTask { [weak self] in await self?.handleIncoming(connection) }
    }

    private func handleIncoming(_ connection: NWConnection) async {
        let channel = LANFramedChannel(connection: connection)
        defer { Task { await channel.cancel() } }
        do {
            let hello = try await channel.receive(LANSyncProtocol.Hello.self)
            guard hello.version == LANSyncProtocol.version, hello.deviceID != deviceID else {
                throw LANSyncProtocol.ProtocolError.incompatibleVersion
            }
            switch hello.mode {
            case .pair: try await handleIncomingPair(hello, channel: channel)
            case .sync: try await handleIncomingSync(hello, channel: channel)
            case .unpair: try await handleIncomingUnpair(hello, channel: channel)
            }
        } catch {
            AppLog.warn(.localAPI, "LAN sync incoming connection failed: \(error.localizedDescription)")
        }
    }

    private func handleIncomingPair(_ hello: LANSyncProtocol.Hello, channel: LANFramedChannel) async throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverHello = LANSyncProtocol.ServerHello(
            version: LANSyncProtocol.version,
            deviceID: deviceID,
            displayName: deviceName,
            publicKey: privateKey.publicKey.rawRepresentation,
            nonce: try LANSyncProtocol.randomBytes(count: 32),
            proof: nil
        )
        try await channel.send(serverHello)
        let context = try LANSyncProtocol.context(clientHello: hello, serverHello: serverHello, privateKey: privateKey)
        let requestID = UUID()
        incomingPairRequests.append(LANIncomingPairRequest(
            id: requestID,
            deviceID: hello.deviceID,
            name: hello.displayName,
            code: context.code
        ))
        let approvalTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            self?.finishApproval(requestID, approved: false)
        }
        let approved = await withCheckedContinuation { approvalContinuations[requestID] = $0 }
        approvalTimeout.cancel()
        incomingPairRequests.removeAll { $0.id == requestID }
        guard approved else {
            try await channel.send(LANSyncProtocol.PairDecision(accepted: false, sealedSecret: nil))
            return
        }
        let secret = try LANSyncProtocol.randomBytes(count: 32)
        try secretStore.store(secret, for: hello.deviceID)
        remember(LANPairedDevice(id: hello.deviceID, name: hello.displayName))
        let sealed = try LANSyncProtocol.seal(LANSyncProtocol.PairSecretPayload(secret: secret), using: context.key)
        try await channel.send(LANSyncProtocol.PairDecision(accepted: true, sealedSecret: sealed))
        AppLog.info(.localAPI, "LAN sync paired with \(hello.displayName)")
    }

    private func handleIncomingSync(_ hello: LANSyncProtocol.Hello, channel: LANFramedChannel) async throws {
        guard let secret = try secretStore.secret(for: hello.deviceID),
              pairedDevices.contains(where: { $0.id == hello.deviceID }) else {
            // Tell the requester why instead of dropping the connection — otherwise all it can
            // report is a generic timeout. Advisory only; the requester never auto-forgets on it.
            try await channel.send(LANSyncProtocol.ServerHello(
                version: LANSyncProtocol.version, deviceID: deviceID, displayName: deviceName,
                publicKey: Data(), nonce: Data(), proof: nil, notPaired: true
            ))
            throw LANSyncProtocol.ProtocolError.missingPairSecret
        }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let unsigned = LANSyncProtocol.ServerHello(
            version: LANSyncProtocol.version,
            deviceID: deviceID,
            displayName: deviceName,
            publicKey: privateKey.publicKey.rawRepresentation,
            nonce: try LANSyncProtocol.randomBytes(count: 32),
            proof: nil
        )
        let context = try LANSyncProtocol.context(
            clientHello: hello, serverHello: unsigned, privateKey: privateKey, pairSecret: secret
        )
        let serverHello = LANSyncProtocol.ServerHello(
            version: unsigned.version, deviceID: unsigned.deviceID, displayName: unsigned.displayName,
            publicKey: unsigned.publicKey, nonce: unsigned.nonce,
            proof: LANSyncProtocol.proof(role: "server", transcript: context.transcript, pairSecret: secret)
        )
        try await channel.send(serverHello)
        let clientProof = try await channel.receive(LANSyncProtocol.AuthProof.self)
        guard LANSyncProtocol.verify(
            clientProof.proof, role: "client", transcript: context.transcript, pairSecret: secret
        ) else { throw LANSyncProtocol.ProtocolError.authenticationFailed }
        let payload = LANSyncProtocol.SnapshotPayload(
            version: LANSyncProtocol.version,
            deviceID: deviceID,
            generatedAt: Date(),
            snapshots: localSnapshots()
        )
        try await channel.sendFrame(try LANSyncProtocol.seal(payload, using: context.key))
    }

    /// A peer the user unpaired is telling us to drop our side too. Same mutual HMAC authentication
    /// as a sync — only a Mac that still holds the shared secret can trigger the removal.
    private func handleIncomingUnpair(_ hello: LANSyncProtocol.Hello, channel: LANFramedChannel) async throws {
        guard let secret = try secretStore.secret(for: hello.deviceID),
              pairedDevices.contains(where: { $0.id == hello.deviceID }) else { return }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let unsigned = LANSyncProtocol.ServerHello(
            version: LANSyncProtocol.version,
            deviceID: deviceID,
            displayName: deviceName,
            publicKey: privateKey.publicKey.rawRepresentation,
            nonce: try LANSyncProtocol.randomBytes(count: 32),
            proof: nil
        )
        let context = try LANSyncProtocol.context(
            clientHello: hello, serverHello: unsigned, privateKey: privateKey, pairSecret: secret
        )
        try await channel.send(LANSyncProtocol.ServerHello(
            version: unsigned.version, deviceID: unsigned.deviceID, displayName: unsigned.displayName,
            publicKey: unsigned.publicKey, nonce: unsigned.nonce,
            proof: LANSyncProtocol.proof(role: "server", transcript: context.transcript, pairSecret: secret)
        ))
        let clientProof = try await channel.receive(LANSyncProtocol.AuthProof.self)
        guard LANSyncProtocol.verify(
            clientProof.proof, role: "client", transcript: context.transcript, pairSecret: secret
        ) else { throw LANSyncProtocol.ProtocolError.authenticationFailed }
        let name = pairedDevices.first { $0.id == hello.deviceID }?.name ?? hello.displayName
        pairedDevices.removeAll { $0.id == hello.deviceID }
        persistPairedDevices()
        try? secretStore.deleteSecret(for: hello.deviceID)
        removeRemoteSnapshots(hello.deviceID)
        peerStates[hello.deviceID] = nil
        rebuildNearbyDevices()
        AppLog.info(.localAPI, "LAN sync unpaired by \(name)")
    }

    /// The outbound half of Forget: authenticate with the still-held secret and ask the peer to drop
    /// its pairing entry. Best-effort — failure only means the peer shows a stale entry until its
    /// next sync attempt errors.
    private func sendUnpair(deviceID remoteID: String, endpoint: NWEndpoint, secret: Data) async {
        let channel = LANFramedChannel(connection: NWConnection(to: endpoint, using: .tcp))
        defer { Task { await channel.cancel() } }
        do {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let hello = LANSyncProtocol.Hello(
                version: LANSyncProtocol.version,
                mode: .unpair,
                deviceID: deviceID,
                displayName: deviceName,
                publicKey: privateKey.publicKey.rawRepresentation,
                nonce: try LANSyncProtocol.randomBytes(count: 32)
            )
            try await channel.send(hello)
            let serverHello = try await channel.receive(LANSyncProtocol.ServerHello.self)
            guard serverHello.deviceID == remoteID else { throw LANSyncProtocol.ProtocolError.authenticationFailed }
            let context = try LANSyncProtocol.context(
                clientHello: hello, serverHello: serverHello, privateKey: privateKey, pairSecret: secret
            )
            guard let proof = serverHello.proof, LANSyncProtocol.verify(
                proof, role: "server", transcript: context.transcript, pairSecret: secret
            ) else { throw LANSyncProtocol.ProtocolError.authenticationFailed }
            try await channel.send(LANSyncProtocol.AuthProof(
                proof: LANSyncProtocol.proof(role: "client", transcript: context.transcript, pairSecret: secret)
            ))
        } catch {
            AppLog.info(.localAPI, "LAN sync unpair notice to \(remoteID) not delivered: \(error.localizedDescription)")
        }
    }

    private func performPairing(deviceID remoteID: String, name: String, endpoint: NWEndpoint) async {
        let channel = LANFramedChannel(connection: NWConnection(to: endpoint, using: .tcp), timeout: 120)
        defer { Task { await channel.cancel() } }
        do {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let hello = LANSyncProtocol.Hello(
                version: LANSyncProtocol.version,
                mode: .pair,
                deviceID: deviceID,
                displayName: deviceName,
                publicKey: privateKey.publicKey.rawRepresentation,
                nonce: try LANSyncProtocol.randomBytes(count: 32)
            )
            try await channel.send(hello)
            let serverHello = try await channel.receive(LANSyncProtocol.ServerHello.self)
            guard serverHello.deviceID == remoteID else { throw LANSyncProtocol.ProtocolError.authenticationFailed }
            let context = try LANSyncProtocol.context(clientHello: hello, serverHello: serverHello, privateKey: privateKey)
            outgoingPairing = .compareCode(deviceID: remoteID, name: name, code: context.code)
            let decision = try await channel.receive(LANSyncProtocol.PairDecision.self)
            guard decision.accepted, let sealed = decision.sealedSecret else {
                throw LANSyncProtocol.ProtocolError.pairingDenied
            }
            let payload = try LANSyncProtocol.open(
                LANSyncProtocol.PairSecretPayload.self, sealed: sealed, using: context.key
            )
            try secretStore.store(payload.secret, for: remoteID)
            remember(LANPairedDevice(id: remoteID, name: serverHello.displayName))
            outgoingPairing = nil
            await sync(device: LANPairedDevice(id: remoteID, name: serverHello.displayName), endpoint: endpoint)
        } catch {
            outgoingPairing = .failed(deviceID: remoteID, name: name, message: error.localizedDescription)
            AppLog.warn(.localAPI, "LAN sync pairing failed: \(error.localizedDescription)")
        }
    }

    private func sync(device: LANPairedDevice, endpoint: NWEndpoint) async {
        var state = peerStates[device.id] ?? LANPeerSyncState(isAvailable: true)
        guard !state.isSyncing else { return }
        state.isAvailable = true
        state.isSyncing = true
        state.errorMessage = nil
        peerStates[device.id] = state
        let channel = LANFramedChannel(connection: NWConnection(to: endpoint, using: .tcp))
        defer { Task { await channel.cancel() } }
        do {
            guard let secret = try secretStore.secret(for: device.id) else {
                throw LANSyncProtocol.ProtocolError.missingPairSecret
            }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let hello = LANSyncProtocol.Hello(
                version: LANSyncProtocol.version,
                mode: .sync,
                deviceID: deviceID,
                displayName: deviceName,
                publicKey: privateKey.publicKey.rawRepresentation,
                nonce: try LANSyncProtocol.randomBytes(count: 32)
            )
            try await channel.send(hello)
            let serverHello = try await channel.receive(LANSyncProtocol.ServerHello.self)
            guard serverHello.deviceID == device.id else { throw LANSyncProtocol.ProtocolError.authenticationFailed }
            if serverHello.notPaired == true { throw LANSyncProtocol.ProtocolError.peerNotPaired }
            let context = try LANSyncProtocol.context(
                clientHello: hello, serverHello: serverHello, privateKey: privateKey, pairSecret: secret
            )
            guard let proof = serverHello.proof, LANSyncProtocol.verify(
                proof, role: "server", transcript: context.transcript, pairSecret: secret
            ) else { throw LANSyncProtocol.ProtocolError.authenticationFailed }
            try await channel.send(LANSyncProtocol.AuthProof(
                proof: LANSyncProtocol.proof(role: "client", transcript: context.transcript, pairSecret: secret)
            ))
            let sealed = try await channel.receiveFrame()
            let payload = try LANSyncProtocol.open(
                LANSyncProtocol.SnapshotPayload.self, sealed: sealed, using: context.key
            )
            guard payload.version == LANSyncProtocol.version, payload.deviceID == device.id else {
                throw LANSyncProtocol.ProtocolError.authenticationFailed
            }
            applyRemoteSnapshots(device.id, payload.snapshots)
            state.isSyncing = false
            state.lastSyncedAt = Date()
            state.errorMessage = nil
            peerStates[device.id] = state
        } catch {
            removeRemoteSnapshots(device.id)
            state.isSyncing = false
            state.errorMessage = error.localizedDescription
            peerStates[device.id] = state
            AppLog.warn(.localAPI, "LAN sync fetch from \(device.name) failed: \(error.localizedDescription)")
        }
    }

    private func finishApproval(_ requestID: UUID, approved: Bool) {
        approvalContinuations.removeValue(forKey: requestID)?.resume(returning: approved)
    }

    private func remember(_ device: LANPairedDevice) {
        pairedDevices.removeAll { $0.id == device.id }
        pairedDevices.append(device)
        pairedDevices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var state = peerStates[device.id] ?? LANPeerSyncState()
        state.isAvailable = endpoints[device.id] != nil
        peerStates[device.id] = state
        persistPairedDevices()
        rebuildNearbyDevices()
    }

    private func persistPairedDevices() {
        do { defaults.set(try JSONEncoder().encode(pairedDevices), forKey: Self.pairedDevicesKey) }
        catch { AppLog.error(.config, "LAN paired-device save failed: \(error.localizedDescription)") }
    }

    private static func loadPairedDevices(defaults: UserDefaults) -> [LANPairedDevice] {
        guard let data = defaults.data(forKey: pairedDevicesKey) else { return [] }
        do { return try JSONDecoder().decode([LANPairedDevice].self, from: data) }
        catch {
            AppLog.error(.config, "LAN paired-device load failed: \(error.localizedDescription)")
            return []
        }
    }

    private func launchTask(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        runningTasks[id] = Task { [weak self] in
            await operation()
            self?.runningTasks[id] = nil
        }
    }

    private func serviceName(from endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return "Mac"
    }
}
