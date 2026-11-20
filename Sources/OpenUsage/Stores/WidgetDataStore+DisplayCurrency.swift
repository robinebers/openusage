import Foundation

extension WidgetDataStore {
    static let exchangeRatesMaxAge: TimeInterval = 6 * 60 * 60

    /// The currency an account's money shows in: its own pick, else the one in Settings. Nil shows what the
    /// provider reports.
    func currencyCode(for providerID: String) -> String? {
        guard let own = accountCurrencyCodes[providerID] else { return displayCurrencyCode }
        return own.isEmpty ? nil : own
    }

    /// The currency a metric's money shows in, with the rates to reach it, or nil to show what the provider
    /// reports. Until the first rates arrive, amounts show as reported unless the provider has a fixed rate.
    func displayCurrency(for descriptor: WidgetDescriptor) -> DisplayCurrency? {
        guard let code = currencyCode(for: descriptor.providerID) else { return nil }
        let fixedRates = DisplayCurrency.fixedRates(for: descriptor.providerKind, in: code)
        guard exchangeRates != nil || !fixedRates.isEmpty else { return nil }
        return DisplayCurrency(code: code, rates: exchangeRates, fixedRates: fixedRates)
    }

    /// Reads the day's rates while any account shows a converted currency and the saved ones are over six
    /// hours old. A failed read keeps the saved rates, or amounts as reported when there are none.
    func refreshExchangeRates() async {
        guard displayCurrencyCode != nil || accountCurrencyCodes.values.contains(where: { !$0.isEmpty }) else { return }
        if let exchangeRates, now().timeIntervalSince(exchangeRates.fetchedAt) < Self.exchangeRatesMaxAge { return }
        if let exchangeRatesRead { return await exchangeRatesRead.value }
        let read = Task {
            do {
                let rates = try await exchangeRateClient.latest(now: now())
                exchangeRates = rates
                exchangeRatesFailed = false
                defaults.set(try JSONEncoder().encode(rates), forKey: Self.exchangeRatesKey)
                AppLog.info(.refresh, "exchange rates read for \(rates.day)")
            } catch {
                exchangeRatesFailed = true
                AppLog.warn(.refresh, "exchange rates read failed; amounts keep the saved rates or show as reported: \(error.localizedDescription)")
            }
        }
        exchangeRatesRead = read
        await read.value
        exchangeRatesRead = nil
    }

    static func savedExchangeRates(in defaults: UserDefaults) -> ExchangeRates? {
        guard let data = defaults.data(forKey: exchangeRatesKey) else { return nil }
        do {
            return try JSONDecoder().decode(ExchangeRates.self, from: data)
        } catch {
            AppLog.warn(.cache, "saved exchange rates unreadable; reading them again: \(error.localizedDescription)")
            return nil
        }
    }
}
