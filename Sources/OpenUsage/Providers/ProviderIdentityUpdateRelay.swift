import Foundation

/// Bridges identities selected by a successful Codex refresh into the MainActor data store created
/// later in AppContainer. Delivery is synchronous so that refresh's history is bound before it can be
/// exported; events are still buffered until the sink is installed so startup ordering cannot lose one.
@MainActor
final class ProviderIdentityUpdateRelay {
    private var sink: ((String, String) -> Void)?
    private var pending: [String: String] = [:]

    func submit(providerID: String, identityKey: String) {
        accept(providerID: providerID, identityKey: identityKey)
    }

    func install(_ sink: @escaping (String, String) -> Void) {
        self.sink = sink
        let buffered = pending
        pending.removeAll()
        for (providerID, identityKey) in buffered {
            sink(providerID, identityKey)
        }
    }

    private func accept(providerID: String, identityKey: String) {
        if let sink {
            sink(providerID, identityKey)
        } else {
            pending[providerID] = identityKey
        }
    }
}
