import CryptoKit
import Foundation
import Network
import os
import Security

enum LANSyncProtocol {
    static let version = 1
    static let serviceType = "_openusage._tcp"
    static let maxFrameBytes = 8 * 1024 * 1024

    enum Mode: String, Codable, Sendable { case pair, sync, unpair }

    struct Hello: Codable, Sendable {
        let version: Int
        let mode: Mode
        let deviceID: String
        let displayName: String
        let publicKey: Data
        let nonce: Data
    }

    struct ServerHello: Codable, Sendable {
        let version: Int
        let deviceID: String
        let displayName: String
        let publicKey: Data
        let nonce: Data
        let proof: Data?
        /// True when the responder no longer knows this pairing (e.g. the user hit Forget there).
        /// Sent before authentication, so the requester treats it as advisory only: it improves the
        /// error message but never removes a pairing by itself. Optional so version-1 peers that
        /// don't send the field still decode.
        var notPaired: Bool?
    }

    struct PairDecision: Codable, Sendable {
        let accepted: Bool
        let sealedSecret: Data?
    }

    struct PairSecretPayload: Codable, Sendable { let secret: Data }

    struct AuthProof: Codable, Sendable { let proof: Data }

    struct SnapshotPayload: Codable, Sendable {
        let version: Int
        let deviceID: String
        let generatedAt: Date
        let snapshots: [String: ProviderSnapshot]
    }

    enum ProtocolError: Error, LocalizedError {
        case invalidFrame
        case frameTooLarge
        case incompatibleVersion
        case invalidKey
        case authenticationFailed
        case pairingDenied
        case missingPairSecret
        case peerNotPaired
        case connectionClosed
        case timedOut

        var errorDescription: String? {
            switch self {
            case .invalidFrame: "The nearby Mac sent an invalid message."
            case .frameTooLarge: "The nearby Mac sent too much data."
            case .incompatibleVersion: "The nearby Mac uses an incompatible OpenUsage sync version."
            case .invalidKey: "The nearby Mac sent an invalid security key."
            case .authenticationFailed: "The nearby Mac could not be authenticated."
            case .pairingDenied: "The connection request was declined."
            case .missingPairSecret: "This Mac no longer has the key for that paired device. Pair it again."
            case .peerNotPaired: "That Mac no longer recognizes this connection. Forget it and connect again."
            case .connectionClosed: "The nearby Mac closed the connection."
            case .timedOut: "The nearby Mac didn't respond in time."
            }
        }
    }

    struct SessionContext: Sendable {
        let transcript: Data
        let key: SymmetricKey
        let code: String
    }

    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ProtocolError.invalidKey
        }
        return Data(bytes)
    }

    static func context(
        clientHello: Hello,
        serverHello: ServerHello,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        pairSecret: Data? = nil
    ) throws -> SessionContext {
        guard clientHello.version == version, serverHello.version == version else {
            throw ProtocolError.incompatibleVersion
        }
        let remotePublicData = privateKey.publicKey.rawRepresentation == clientHello.publicKey
            ? serverHello.publicKey : clientHello.publicKey
        let remotePublic: Curve25519.KeyAgreement.PublicKey
        do {
            remotePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicData)
        } catch {
            throw ProtocolError.invalidKey
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: remotePublic)
        let transcript = transcript(clientHello: clientHello, serverHello: serverHello)
        let salt = pairSecret ?? Data(SHA256.hash(data: clientHello.nonce + serverHello.nonce))
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: transcript,
            outputByteCount: 32
        )
        let codeMAC = HMAC<SHA256>.authenticationCode(for: Data("pair-code".utf8) + transcript, using: key)
        let number = codeMAC.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return SessionContext(transcript: transcript, key: key, code: String(format: "%06u", number))
    }

    static func proof(role: String, transcript: Data, pairSecret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(role.utf8) + transcript,
            using: SymmetricKey(data: pairSecret)
        ))
    }

    static func verify(_ proof: Data, role: String, transcript: Data, pairSecret: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: Data(role.utf8) + transcript,
            using: SymmetricKey(data: pairSecret)
        )
    }

    static func seal<T: Encodable>(_ value: T, using key: SymmetricKey) throws -> Data {
        let encoded = try encoder.encode(value)
        return try ChaChaPoly.seal(encoded, using: key).combined
    }

    static func open<T: Decodable>(_ type: T.Type, sealed: Data, using key: SymmetricKey) throws -> T {
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed)
            return try decoder.decode(type, from: ChaChaPoly.open(box, using: key))
        } catch {
            throw ProtocolError.authenticationFailed
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func transcript(clientHello: Hello, serverHello: ServerHello) -> Data {
        var data = Data("OpenUsage LAN sync v\(version)".utf8)
        for part in [
            clientHello.mode.rawValue.data(using: .utf8)!,
            Data(clientHello.deviceID.utf8), Data(clientHello.displayName.utf8),
            Data(serverHello.deviceID.utf8), Data(serverHello.displayName.utf8),
            clientHello.publicKey, serverHello.publicKey,
            clientHello.nonce, serverHello.nonce
        ] {
            var length = UInt32(part.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(part)
        }
        return data
    }
}

protocol LANSyncSecretStoring: Sendable {
    func secret(for deviceID: String) throws -> Data?
    func store(_ secret: Data, for deviceID: String) throws
    func deleteSecret(for deviceID: String) throws
}

struct KeychainLANSyncSecretStore: LANSyncSecretStoring {
    private var service: String {
        (Bundle.main.bundleIdentifier ?? "com.robinebers.openusage") + ".lan-sync"
    }

    func secret(for deviceID: String) throws -> Data? {
        var query = baseQuery(deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LANSyncProtocol.ProtocolError.missingPairSecret
        }
        return data
    }

    func store(_ secret: Data, for deviceID: String) throws {
        let query = baseQuery(deviceID)
        let attributes = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as [String: Any]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw LANSyncProtocol.ProtocolError.invalidKey }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw LANSyncProtocol.ProtocolError.invalidKey
        }
    }

    func deleteSecret(for deviceID: String) throws {
        let status = SecItemDelete(baseQuery(deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LANSyncProtocol.ProtocolError.invalidKey
        }
    }

    private func baseQuery(_ deviceID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID
        ]
    }
}

/// Length-prefixed frames on top of one TCP connection. All application payloads after pairing/auth
/// are ChaCha20-Poly1305 sealed; this type only owns stream framing and a strict allocation cap.
actor LANFramedChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "openusage.lan-sync.connection")
    private let timeout: TimeInterval
    private var buffer = Data()

    init(connection: NWConnection, timeout: TimeInterval = 15) {
        self.connection = connection
        self.timeout = timeout
        // Fail fast instead of hanging into the frame timeout: a connection that can't be established
        // (stale Bonjour endpoint, unreachable peer) parks in `.waiting` and silently retries forever,
        // so pending send/receive callbacks would never fire and every failure would read as a
        // generic "didn't respond in time". Cancelling here makes those callbacks return the real error.
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .waiting(let error), .failed(let error):
                AppLog.warn(.localAPI, "LAN sync connection unusable: \(error.localizedDescription)")
                connection?.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send<T: Encodable>(_ value: T) async throws {
        let payload = try LANSyncProtocol.encoder.encode(value)
        try await sendFrame(payload)
    }

    func receive<T: Decodable>(_ type: T.Type) async throws -> T {
        try LANSyncProtocol.decoder.decode(type, from: await receiveFrame())
    }

    func sendFrame(_ payload: Data) async throws {
        guard payload.count <= LANSyncProtocol.maxFrameBytes else { throw LANSyncProtocol.ProtocolError.frameTooLarge }
        var length = UInt32(payload.count).bigEndian
        let framed = Data(bytes: &length, count: 4) + payload
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let gate = LANContinuationGate(continuation)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                if gate.resume(.failure(LANSyncProtocol.ProtocolError.timedOut)) { connection.cancel() }
            }
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { _ = gate.resume(.failure(error)) }
                else { _ = gate.resume(.success(())) }
            })
        }
    }

    func receiveFrame() async throws -> Data {
        while true {
            if buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length <= LANSyncProtocol.maxFrameBytes else { throw LANSyncProtocol.ProtocolError.frameTooLarge }
                let total = 4 + Int(length)
                if buffer.count >= total {
                    let payload = buffer.subdata(in: 4..<total)
                    buffer.removeSubrange(0..<total)
                    return payload
                }
            }
            // An empty chunk is a receive that completed without data (not end-of-stream — that
            // throws `.connectionClosed` inside `receiveChunk`); loop and keep reading.
            buffer.append(try await receiveChunk())
        }
    }

    func cancel() { connection.cancel() }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = LANContinuationGate(continuation)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                if gate.resume(.failure(LANSyncProtocol.ProtocolError.timedOut)) { connection.cancel() }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { _ = gate.resume(.failure(error)) }
                else if let data, !data.isEmpty { _ = gate.resume(.success(data)) }
                else if complete { _ = gate.resume(.failure(LANSyncProtocol.ProtocolError.connectionClosed)) }
                else { _ = gate.resume(.success(Data())) }
            }
        }
    }
}

private final class LANContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    private let continuation: CheckedContinuation<Value, any Error>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<Value, any Error>) -> Bool {
        let shouldResume = lock.withLock { resumed in
            guard !resumed else { return false }
            resumed = true
            return true
        }
        guard shouldResume else { return false }
        continuation.resume(with: result)
        return true
    }
}
