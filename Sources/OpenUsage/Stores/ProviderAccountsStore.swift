import CryptoKit
import Foundation

/// Card-id helpers for the account-first model. The account occupying a family's default home when
/// first observed keeps the bare family id (`claude`, `codex`) as its permanent record id — that is
/// what makes existing installs migrate by doing nothing. Any later account of the same family mints
/// `family@<hash8>` from its identity key.
enum ProviderAccountID {
    /// The family ids that participate in the account-first model.
    static let families: Set<String> = ["claude", "codex"]

    /// `claude@ab12cd34` — a stable, non-reversible id derived from the account's identity key.
    static func make(family: String, identityKey: String) -> String {
        let digest = SHA256.hash(data: Data(identityKey.lowercased().utf8))
        let hash8 = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(family)@\(hash8)"
    }

    /// The family a card id belongs to: `claude@ab12cd34` → `claude`, bare ids map to themselves.
    static func family(of cardID: String) -> String {
        cardID.firstIndex(of: "@").map { String(cardID[..<$0]) } ?? cardID
    }

    /// Whether a card id names an extra account card (`claude@ab12cd34`) rather than a bare
    /// provider id.
    static func isAccountCard(_ cardID: String) -> Bool {
        cardID.contains("@")
    }
}

/// One place an account is signed in. "Default" is a badge on a source (`holdsDefaultSource`), never
/// a key: it marks who currently occupies the default home, and it never drives ids or sort order —
/// a swap re-points source edges, cards don't move. Phase 1 only observes the default home; later
/// phases add config dirs, cswap vault slots, Codex homes, and Desktop logins as more kinds.
struct ProviderAccountSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The provider's standard home for this machine (`~/.claude`, `~/.codex`, env override).
        case defaultHome
        /// A custom Claude config dir (a `CLAUDE_CONFIG_DIR` home kept besides the default).
        case configDir
    }

    var kind: Kind
    /// Canonical home path the source was observed at.
    var anchor: String?
    var holdsDefaultSource: Bool
    /// `configDir` only: the literal string whose hash names the source's keychain item (Claude Code
    /// hashes `CLAUDE_CONFIG_DIR` exactly as typed, so `~/x` and its absolute spelling differ).
    var keychainLiteral: String?

    init(kind: Kind, anchor: String?, holdsDefaultSource: Bool, keychainLiteral: String? = nil) {
        self.kind = kind
        self.anchor = anchor
        self.holdsDefaultSource = holdsDefaultSource
        self.keychainLiteral = keychainLiteral
    }
}

/// An account as the account-first model sees it: opaque identity key, stable record id minted at
/// creation, and the sources currently attaching to it.
struct ProviderAccountRecord: Codable, Equatable, Sendable {
    /// Stable id minted when the account is first seen; never re-derived. The first account observed
    /// at a family's default home gets the bare family id.
    var id: String
    var family: String
    var identityKey: String
    var label: String?
    /// A user-chosen card name (Rename in the card's context menu / Customize). Wins over `label`
    /// and the id-derived fallback; never touched by reconciliation.
    var customLabel: String?
    var sources: [ProviderAccountSource]
    /// Set by a future "Remove Account…". A tombstoned account is never resurrected by rescans.
    var removedTombstone: Bool = false

    /// The name the card renders under: the user's rename, else the account's own label
    /// ("email (Org Name)"), else the record id itself (`claude@ab12cd34` — owner decision 2).
    var displayLabel: String {
        customLabel?.nilIfEmpty ?? label?.nilIfEmpty ?? id
    }
}

/// The account-first registry (`openusage.providerAccounts.v1`). Reconciled at every launch from the
/// default-home identity reads; authoritative from day one — there is no parallel card model to drift
/// from. With a single account per family (all Phase 1 can observe), the registry is bookkeeping the
/// UI doesn't consult yet; multi-account rendering (Phase 2+) reads cards straight from these records.
@MainActor
final class ProviderAccountsStore {
    static let storageKey = "openusage.providerAccounts.v1"

    private let defaults: UserDefaults
    private(set) var records: [ProviderAccountRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                self.records = try JSONDecoder().decode([ProviderAccountRecord].self, from: data)
            } catch {
                AppLog.error(.config, "provider-account records were undecodable; starting a fresh registry: \(error.localizedDescription)")
                self.records = []
            }
        } else {
            self.records = []
        }
    }

    /// One account observed this launch, before reconciliation assigns (or re-finds) its record id.
    struct Observation {
        var family: String
        var identityKey: String
        var label: String?
        var sources: [ProviderAccountSource]
    }

    /// Merges this launch's observations into the persisted set. Phase 1 semantics: an observation
    /// updates its account's label and sources, or creates the record; the first account of a family
    /// gets the bare family id, a later one mints `family@<hash8>`. Records never move or vanish here
    /// — an account that went unobserved (logged out, unreadable identity) is simply left as it was,
    /// except that a newly observed default-home holder takes the default badge off every sibling.
    @discardableResult
    func reconcile(with observations: [Observation]) -> [ProviderAccountRecord] {
        var updated = records
        var changed = false

        for observation in observations {
            let index = updated.firstIndex {
                $0.family == observation.family && $0.identityKey == observation.identityKey
            }
            if let index {
                guard !updated[index].removedTombstone else { continue }
                var record = updated[index]
                record.label = observation.label ?? record.label
                record.sources = observation.sources
                if record != updated[index] {
                    updated[index] = record
                    changed = true
                }
            } else {
                updated.append(ProviderAccountRecord(
                    id: Self.availableID(for: observation, in: updated),
                    family: observation.family,
                    identityKey: observation.identityKey,
                    label: observation.label,
                    sources: observation.sources
                ))
                changed = true
            }

            // The default badge is exclusive per family: when this observation holds it, strip it
            // from every sibling record (the account that swapped out no longer answers the bare id).
            if observation.sources.contains(where: \.holdsDefaultSource) {
                for index in updated.indices
                where updated[index].family == observation.family
                    && updated[index].identityKey != observation.identityKey
                    && updated[index].sources.contains(where: \.holdsDefaultSource)
                {
                    updated[index].sources = updated[index].sources.map { source in
                        var source = source
                        source.holdsDefaultSource = false
                        return source
                    }
                    changed = true
                }
            }
        }

        if changed {
            records = updated
            persist()
        }
        return records
    }

    /// Stores a user rename for a card; `nil` or blank clears it back to the derived name.
    func rename(cardID: String, to name: String?) {
        guard let index = records.firstIndex(where: { $0.id == cardID }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard records[index].customLabel != trimmed else { return }
        records[index].customLabel = trimmed
        persist()
    }

    /// The record currently holding a family's default badge, if any.
    func defaultBadgeHolder(family: String) -> ProviderAccountRecord? {
        records.first { record in
            record.family == family
                && !record.removedTombstone
                && record.sources.contains(where: \.holdsDefaultSource)
        }
    }

    /// The bare family id when free (the migration-killing rule: the first account observed at the
    /// default home IS the existing card), else an identity-derived `family@<hash8>` id. Only an
    /// account observed at the family's DEFAULT home may claim the bare id — that id's runtime reads
    /// the default home, so handing it to a custom-config-dir account would point the existing card
    /// at a login it can't read.
    private static func availableID(for observation: Observation, in records: [ProviderAccountRecord]) -> String {
        let observedAtDefaultHome = observation.sources.contains { $0.kind == .defaultHome }
        if observedAtDefaultHome, !records.contains(where: { $0.id == observation.family }) {
            return observation.family
        }
        let derived = ProviderAccountID.make(family: observation.family, identityKey: observation.identityKey)
        guard records.contains(where: { $0.id == derived }) else { return derived }
        // A hash-prefix collision between two distinct identities of one family; salt until free.
        var attempt = 0
        while true {
            let salted = ProviderAccountID.make(
                family: observation.family,
                identityKey: "\(observation.identityKey)|\(attempt)"
            )
            if !records.contains(where: { $0.id == salted }) { return salted }
            attempt += 1
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            AppLog.error(.config, "failed to encode provider-account records; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
