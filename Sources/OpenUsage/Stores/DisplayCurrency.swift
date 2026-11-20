import Foundation

/// Money shown in a currency the user picks instead of the one each provider reports, converted at the
/// European Central Bank's daily reference rates. Only what the dashboard and menu bar show is converted;
/// snapshots and the command line keep each provider's own amounts.
struct DisplayCurrency: Hashable, Sendable {
    static let choices = ["USD", "EUR", "GBP", "INR", "CNY", "JPY", "CAD", "AUD"]

    let code: String
    var rates: ExchangeRates?
    /// Units of `code` per unit of a source currency, used instead of the ECB's rate for that currency.
    var fixedRates: [String: Double] = [:]

    /// The amount in `code`, or nil when neither a fixed rate nor the ECB's rates cover `source`.
    func convert(_ amount: Double, from source: String) -> Double? {
        if source == code { return amount }
        if let fixed = fixedRates[source] { return amount * fixed }
        guard let from = rates?.perEuro(source), let to = rates?.perEuro(code) else { return nil }
        return amount / from * to
    }

    /// Rates the owner set for one provider in place of the ECB's: Plivo's dollars show at ₹80 each.
    static func fixedRates(for kind: ProviderKind, in code: String) -> [String: Double] {
        kind == .plivo && code == "INR" ? ["USD": 80] : [:]
    }

    static func name(for code: String) -> String {
        Locale(identifier: "en_US").localizedString(forCurrencyCode: code) ?? code
    }

    static func label(for code: String) -> String {
        "\(name(for: code)) (\(code))"
    }
}

/// What one euro buys in each currency, for one ECB publication day.
struct ExchangeRates: Codable, Hashable, Sendable {
    var day: String
    var perEuroRates: [String: Double]
    var fetchedAt: Date

    func perEuro(_ code: String) -> Double? {
        code == "EUR" ? 1 : perEuroRates[code]
    }
}

/// Reads the ECB's latest reference rates through Frankfurter, which needs no key.
struct ExchangeRateClient: Sendable {
    static let latestURL = URL(string: "https://api.frankfurter.dev/v1/latest")!

    var http: any HTTPClient

    func latest(now: Date) async throws -> ExchangeRates {
        let response = try await LoginHTTP.get(Self.latestURL, using: http, headers: ["Accept": "application/json"])
        guard (200..<300).contains(response.statusCode) else { throw ProviderError.failed(response, now: now) }
        return try Self.parse(response.body, fetchedAt: now)
    }

    static func parse(_ body: Data, fetchedAt: Date) throws -> ExchangeRates {
        guard let root = ProviderParse.jsonObject(body), root["base"] as? String == "EUR",
              let day = root["date"] as? String, let listed = root["rates"] as? [String: Any], !listed.isEmpty else {
            throw ProviderError.invalidResponse
        }
        var rates: [String: Double] = [:]
        for (code, value) in listed {
            guard let rate = ProviderParse.number(value), rate > 0 else { throw ProviderError.invalidResponse }
            rates[code] = rate
        }
        return ExchangeRates(day: day, perEuroRates: rates, fetchedAt: fetchedAt)
    }
}
