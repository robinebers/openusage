import Foundation

/// Matches synced peer histories to this Mac's cards by ACCOUNT identity instead of by card id.
///
/// The same account can be the default card on one Mac and an instance card on another (swap tools
/// flip which login is "default" all the time), so card ids don't travel: a peer's `claude` entry may
/// belong to the account this Mac shows as `claude@ab12cd34`, and vice versa. v2 documents carry a
/// per-card identity map that makes the match exact; v1 documents (no identities) keep the legacy
/// same-card-id merge for non-instance ids. Peer accounts with no card on this Mac at all become
/// `remoteOnly` entries — surfaced in Total Spend only, never as ghost cards.
enum PeerHistoryRemapper {
    struct Remapped {
        /// Peer histories addressed to a LOCAL card id, ready for the same-id day merge.
        var histories: [(cardID: String, history: ProviderUsageHistory)] = []
        /// Peer accounts with no local card, keyed by identity.
        var remoteOnly: [RemoteOnlyHistory] = []
    }

    struct RemoteOnlyHistory {
        var identityKey: String
        var baseProviderID: String
        var deviceNames: [String]
        var histories: [ProviderUsageHistory]
    }

    /// `localIdentityByCardID` is this Mac's card → identity map (default cards + visible instances).
    static func remap(
        documents: [UsageHistoryDocument],
        localIdentityByCardID: [String: String]
    ) -> Remapped {
        // Invert to identity → card, preferring the DEFAULT card when an identity appears twice (a
        // suppressed instance record and the default card can momentarily share one identity).
        var localCardByIdentity: [String: String] = [:]
        for (cardID, identity) in localIdentityByCardID.sorted(by: { $0.key < $1.key }) {
            if let existing = localCardByIdentity[identity], !ProviderInstanceID.isInstance(existing) {
                continue
            }
            if ProviderInstanceID.isInstance(cardID), localCardByIdentity[identity] != nil {
                continue
            }
            localCardByIdentity[identity] = cardID
        }

        var result = Remapped()
        var remoteByIdentity: [String: RemoteOnlyHistory] = [:]

        for document in UsageHistoryDocument.newestByDevice(documents) {
            for (peerCardID, history) in document.providers.sorted(by: { $0.key < $1.key }) {
                let base = ProviderInstanceID.base(of: peerCardID)
                if let identity = document.identities?[peerCardID] {
                    if let localCard = localCardByIdentity[identity] {
                        result.histories.append((localCard, history))
                    } else {
                        var entry = remoteByIdentity[identity] ?? RemoteOnlyHistory(
                            identityKey: identity, baseProviderID: base, deviceNames: [], histories: []
                        )
                        if !entry.deviceNames.contains(document.deviceName) {
                            entry.deviceNames.append(document.deviceName)
                        }
                        entry.histories.append(history)
                        remoteByIdentity[identity] = entry
                    }
                    continue
                }
                // No identity recorded (v1 document, or a card this peer couldn't identify):
                // non-instance ids keep the legacy same-card-id merge; instance ids still match when
                // this Mac has the same identity-derived card id, else they're remote-only.
                if !ProviderInstanceID.isInstance(peerCardID) {
                    result.histories.append((peerCardID, history))
                } else if localIdentityByCardID[peerCardID] != nil {
                    result.histories.append((peerCardID, history))
                } else {
                    var entry = remoteByIdentity[peerCardID] ?? RemoteOnlyHistory(
                        identityKey: peerCardID, baseProviderID: base, deviceNames: [], histories: []
                    )
                    if !entry.deviceNames.contains(document.deviceName) {
                        entry.deviceNames.append(document.deviceName)
                    }
                    entry.histories.append(history)
                    remoteByIdentity[peerCardID] = entry
                }
            }
        }

        result.remoteOnly = remoteByIdentity.values.sorted { $0.identityKey < $1.identityKey }
        return result
    }
}
