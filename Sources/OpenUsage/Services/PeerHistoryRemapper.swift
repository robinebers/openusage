import Foundation

/// Matches synced peer histories to this Mac's cards by ACCOUNT identity instead of by card id.
///
/// The same account can be the default card on one Mac and an extra account card on another (which
/// login holds a family's default home differs per machine), so card ids don't travel: a peer's
/// `claude` entry may belong to the account this Mac shows as `claude@ab12cd34`, and vice versa. v2
/// documents carry a per-card identity map that makes the match exact; v1 documents (no identities)
/// keep the legacy same-card-id merge for bare ids. Peer accounts with no card on this Mac at all
/// become `remoteOnly` entries — surfaced in Total Spend only, never as ghost cards.
enum PeerHistoryRemapper {
    struct Remapped {
        /// Peer histories addressed to a LOCAL card id, ready for the same-id day merge.
        var histories: [(cardID: String, history: ProviderUsageHistory)] = []
        /// Peer accounts with no local card, keyed by identity.
        var remoteOnly: [RemoteOnlyHistory] = []
    }

    struct RemoteOnlyHistory {
        var identityKey: String
        var family: String
        var deviceNames: [String]
        var histories: [ProviderUsageHistory]
    }

    /// `localIdentityByCardID` is this Mac's card → identity map (the launch account pass's
    /// `identityKeysByCard`).
    static func remap(
        documents: [UsageHistoryDocument],
        localIdentityByCardID: [String: String]
    ) -> Remapped {
        // Invert to identity → card, preferring the bare (default) card when an identity appears on
        // two local cards at once (transiently possible around a swap).
        var localCardByIdentity: [String: String] = [:]
        for (cardID, identity) in localIdentityByCardID.sorted(by: { $0.key < $1.key }) {
            if let existing = localCardByIdentity[identity], !ProviderAccountID.isAccountCard(existing) {
                continue
            }
            if ProviderAccountID.isAccountCard(cardID), localCardByIdentity[identity] != nil {
                continue
            }
            localCardByIdentity[identity] = cardID
        }

        var result = Remapped()
        var remoteByIdentity: [String: RemoteOnlyHistory] = [:]
        func collectRemoteOnly(identity: String, family: String, deviceName: String, history: ProviderUsageHistory) {
            var entry = remoteByIdentity[identity] ?? RemoteOnlyHistory(
                identityKey: identity, family: family, deviceNames: [], histories: []
            )
            if !entry.deviceNames.contains(deviceName) {
                entry.deviceNames.append(deviceName)
            }
            entry.histories.append(history)
            remoteByIdentity[identity] = entry
        }

        for document in UsageHistoryDocument.newestByDevice(documents) {
            for (peerCardID, history) in document.providers.sorted(by: { $0.key < $1.key }) {
                let family = ProviderAccountID.family(of: peerCardID)
                if let identity = document.identities?[peerCardID] {
                    if let localCard = localCardByIdentity[identity] {
                        result.histories.append((localCard, history))
                    } else {
                        collectRemoteOnly(identity: identity, family: family, deviceName: document.deviceName, history: history)
                    }
                    continue
                }
                // No identity recorded (v1 document, or a card this peer couldn't identify): bare
                // ids keep the legacy same-card-id merge; account-card ids still match when this Mac
                // has the same identity-derived card id, else they're remote-only.
                if !ProviderAccountID.isAccountCard(peerCardID) || localIdentityByCardID[peerCardID] != nil {
                    result.histories.append((peerCardID, history))
                } else {
                    collectRemoteOnly(identity: peerCardID, family: family, deviceName: document.deviceName, history: history)
                }
            }
        }

        result.remoteOnly = remoteByIdentity.values.sorted { $0.identityKey < $1.identityKey }
        return result
    }
}
