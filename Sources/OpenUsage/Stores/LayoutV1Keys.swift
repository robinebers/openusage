import Foundation

/// 0.7.x's layout under the `openusage.layout.v1` keys, which this build reads and never writes so a
/// downgrade to 0.7.x finds its layout as it left it.
struct LayoutV1Keys {
    let placed: [String]?
    let providerOrder: [String]?
    let metricOrderByProvider: [String: [String]]?
    let menuBarPins: [String]?
    let enabledProviders: [String]?

    init(defaults: UserDefaults) {
        let key = "openusage.layout.v1"
        placed = Self.decode([Placed].self, key, defaults)?.map(\.descriptorID)
        providerOrder = Self.decode([String].self, "\(key).providerOrder", defaults)
        metricOrderByProvider = Self.decode([String: [String]].self, "\(key).metricOrderByProvider", defaults)
        menuBarPins = defaults.stringArray(forKey: "\(key).menuBarPins")
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
    var hidden: [String]
    var stars: [String]
    var metricOrder: [String]?
    /// Where the account goes among the others, or nil when 0.7.x saved no place for its provider.
    var providerIndex: Int?
}

extension LayoutV1Keys {
    /// The metric keys 0.7.16 had for each provider. 0.7.x's layout speaks only for these: a metric added
    /// since is new to the user and starts shown.
    static let metricKeys: [ProviderKind: Set<String>] = [
        .claude: ["session", "weekly", "fable", "sonnet", "extra", "rateLimitResets", "trend", "today", "yesterday", "last30"],
        .codex: ["session", "weekly", "spark", "sparkWeekly", "credits", "rateLimitResets", "trend", "today", "yesterday", "last30"],
        .cursor: ["usage", "auto", "api", "grokBot", "onDemand", "requests", "credits", "trend", "today", "yesterday", "last30"],
        .antigravity: ["geminiPro", "geminiWeekly", "argonWeekly", "claude", "claudeWeekly", "trend", "today", "yesterday", "last30"],
        .copilot: ["premium", "extra", "orgCredits", "orgSpend", "chat", "completions"],
        .grok: ["weekly", "payAsYouGo", "trend", "today", "yesterday", "last30"],
        .ollama: ["session", "weekly", "monthly", "purchasedCredits"],
        .opencodeGo: ["session", "weekly", "monthly", "trend", "today", "yesterday", "last30"],
        .openrouter: ["credits", "balance", "today", "week", "month", "keyLimit"],
        .zai: ["session", "weekly", "webSearches"]
    ]

    /// The layout of the account 0.7.x showed first for `provider`'s kind, mapped onto `metrics` and placed
    /// among `others`, the providers already shown, in order. Nil when 0.7.x had the provider off.
    func carriedOver(to provider: Provider, metrics: [WidgetDescriptor], among others: [Provider]) -> CarriedLayout? {
        guard enabledProviders?.contains(where: { Self.kind(of: $0) == provider.kind }) == true,
              let account = firstAccount(of: provider.kind) ?? menuBarPins.map({ _ in provider.kind.rawValue })
        else { return nil }
        let shown = placed.map { Set(Self.keys(of: account, in: $0)) }
        let starred: [WidgetDescriptor]? = menuBarPins.flatMap { pins in
            let keys = Self.keys(of: account, in: pins)
            let mapped = metrics.filter { keys.contains($0.key) }
            return mapped.isEmpty && !keys.isEmpty ? nil : mapped
        }
        let known = Self.metricKeys[provider.kind] ?? []
        var hidden = shown.map { shown in
            metrics.filter { known.contains($0.key) && !shown.contains($0.key) && !(starred ?? []).contains($0) }
        } ?? []
        if hidden.count == metrics.count { hidden = [] }

        return CarriedLayout(
            hidden: hidden.map(\.id),
            stars: (starred ?? metrics.filter { $0.isPinnedByDefault && !hidden.contains($0) }).map(\.id),
            metricOrder: metricOrderByProvider?[account].map { ids in
                Self.keys(of: account, in: ids).compactMap { key in metrics.first { $0.key == key }?.id }
            },
            providerIndex: providerIndex(of: provider.kind, among: others.map(\.kind))
        )
    }

    /// The account 0.7.x showed first for `kind`: by its saved provider order, then its dashboard order.
    private func firstAccount(of kind: ProviderKind) -> String? {
        let accounts = (providerOrder ?? [])
            + (placed ?? []).map(Self.account(of:))
            + (metricOrderByProvider?.keys.sorted() ?? [])
            + (menuBarPins ?? []).map(Self.account(of:)).sorted()
        return accounts.first { Self.kind(of: $0) == kind }
    }

    /// After the last provider 0.7.x ordered before `kind`, or first when none was.
    private func providerIndex(of kind: ProviderKind, among kinds: [ProviderKind]) -> Int? {
        var order: [ProviderKind] = []
        for kind in (providerOrder ?? []).compactMap(Self.kind(of:)) where !order.contains(kind) {
            order.append(kind)
        }
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
