import Foundation

/// 0.7.x's layout under the `openusage.layout.v1` keys, which this build reads and never writes so a
/// downgrade to 0.7.x finds its layout as it left it.
struct LayoutV1Keys {
    let placed: [String]?
    let providerOrder: [String]?
    let metricOrderByProvider: [String: [String]]?
    let enabledProviders: [String]?

    init(defaults: UserDefaults) {
        let key = "openusage.layout.v1"
        placed = Self.decode([Placed].self, key, defaults)?.map(\.descriptorID)
        providerOrder = Self.decode([String].self, "\(key).providerOrder", defaults)
        metricOrderByProvider = Self.decode([String: [String]].self, "\(key).metricOrderByProvider", defaults)
        enabledProviders = defaults.stringArray(forKey: "openusage.enabledProviders.v1")
    }

    private struct Placed: Decodable {
        let descriptorID: String
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.warn(.config, "layout '\(key)' failed to decode; leaving it out: \(error.localizedDescription)")
            return nil
        }
    }
}

/// A 0.7.x account's layout, mapped onto an account added today.
struct CarriedLayout {
    var metricOrder: [String]?
    /// Where the account goes among the others, or nil when 0.7.x saved no place for its provider.
    var providerIndex: Int?
}

extension LayoutV1Keys {
    /// The layout of the account 0.7.x showed first for `provider`'s kind, mapped onto `metrics` and placed
    /// among `others`, the providers already shown, in order. Nil when 0.7.x had the provider off.
    func carriedOver(to provider: Provider, metrics: [WidgetDescriptor], among others: [Provider]) -> CarriedLayout? {
        guard let account = firstAccount(of: provider.kind) else { return nil }
        return CarriedLayout(
            metricOrder: metricOrderByProvider?[account].map { ids in
                Self.keys(of: account, in: ids).compactMap { key in metrics.first { $0.key == key }?.id }
            },
            providerIndex: providerIndex(of: provider.kind, among: others.map(\.kind))
        )
    }

    /// The enabled account 0.7.x showed first for `kind`: by its saved provider order, then its dashboard order.
    private func firstAccount(of kind: ProviderKind) -> String? {
        let enabled = (enabledProviders ?? []).filter { Self.kind(of: $0) == kind }
        let accounts = (providerOrder ?? [])
            + (placed ?? []).map(Self.account(of:))
            + (metricOrderByProvider?.keys.sorted() ?? [])
        return accounts.first(where: enabled.contains)
    }

    /// After the last provider 0.7.x ordered before `kind`, or first when none was.
    private func providerIndex(of kind: ProviderKind, among kinds: [ProviderKind]) -> Int? {
        let enabled = Set(enabledProviders ?? [])
        let order = (providerOrder ?? []).filter(enabled.contains).compactMap(Self.kind(of:))
        guard let rank = order.firstIndex(of: kind) else { return nil }
        let before = kinds.lastIndex { other in order.firstIndex(of: other).map { $0 < rank } ?? false }
        return before.map { $0 + 1 } ?? 0
    }

    private static func keys(of account: String, in ids: [String]) -> [String] {
        ids.compactMap { $0.hasPrefix("\(account).") ? String($0.dropFirst(account.count + 1)) : nil }
    }

    private static func account(of id: String) -> String {
        String(id.prefix { $0 != "." })
    }

    private static func kind(of account: String) -> ProviderKind? {
        ProviderKind(rawValue: String(account.prefix { $0 != "@" }))
    }
}
