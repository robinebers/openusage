import Foundation

struct LANPairedDevice: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
}

struct LANNearbyDevice: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let isPaired: Bool
}

struct LANIncomingPairRequest: Identifiable, Sendable {
    let id: UUID
    let deviceID: String
    let name: String
    let code: String
}

enum LANOutgoingPairing: Equatable, Sendable {
    case connecting(deviceID: String, name: String)
    case compareCode(deviceID: String, name: String, code: String)
    case failed(deviceID: String, name: String, message: String)

    /// The Mac being paired with; the Settings list hides its plain discovered row while this
    /// status card is on screen so the device doesn't appear twice.
    var deviceID: String {
        switch self {
        case .connecting(let id, _), .compareCode(let id, _, _), .failed(let id, _, _): id
        }
    }
}

struct LANPeerSyncState: Equatable, Sendable {
    var isAvailable = false
    var isSyncing = false
    var lastSyncedAt: Date?
    var errorMessage: String?
}
