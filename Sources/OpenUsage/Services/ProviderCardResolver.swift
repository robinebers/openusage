import Foundation

/// Resolves a bare family id (`claude`, `codex`) to the card that should answer for it — the alias
/// rule of the account-first model, threaded through the one-shot CLI (`UsageReader`) and the local
/// HTTP API. With a single account per family (all Phase 1 can observe) the answering card IS the
/// bare id, so resolution is pass-through in practice; the rules and their order are pinned by tests
/// now so multi-account phases only have to swap the inputs.
struct ProviderCardResolver: Sendable {
    struct Family: Sendable {
        var id: String
        /// The card id of the account holding the default source this launch; `nil` when the default
        /// login is absent or its identity unresolved.
        var defaultSourceHolderID: String?
        /// The family's enabled cards, dashboard order.
        var enabledCardIDs: [String]
    }

    private let families: [String: Family]

    init(families: [Family]) {
        self.families = Dictionary(uniqueKeysWithValues: families.map { ($0.id, $0) })
    }

    /// Rule order (do not reorder — pinned by tests):
    /// 1. the default-source holder's card,
    /// 2. the sole enabled family card,
    /// 3. the family empty state — the bare id itself.
    /// Anything that isn't a family id (direct card ids, every other provider) passes through untouched.
    func resolve(_ requestedID: String) -> String {
        guard let family = families[requestedID] else { return requestedID }
        if let holder = family.defaultSourceHolderID { return holder }
        if family.enabledCardIDs.count == 1 { return family.enabledCardIDs[0] }
        return family.id
    }

    /// Production wiring: the bare card holds the default source exactly when the launch account pass
    /// resolved the family's default login (`ProviderAccountAssembly`). Enabled cards come from the
    /// registry filtered through enablement.
    static func make(
        registryProviderIDs: [String],
        familyIDs: Set<String> = ProviderAccountID.families,
        defaultResolvedFamilyIDs: Set<String>,
        isProviderEnabled: (String) -> Bool
    ) -> ProviderCardResolver {
        ProviderCardResolver(families: familyIDs.map { familyID in
            Family(
                id: familyID,
                defaultSourceHolderID: defaultResolvedFamilyIDs.contains(familyID) ? familyID : nil,
                enabledCardIDs: registryProviderIDs.filter {
                    ProviderAccountID.family(of: $0) == familyID && isProviderEnabled($0)
                }
            )
        })
    }
}
