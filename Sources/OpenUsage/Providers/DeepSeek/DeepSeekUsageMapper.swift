import Foundation

enum DeepSeekUsageMapper {
    struct Balance: Sendable {
        var currency: String
        var total: Double
        var paid: Double
        var granted: Double
        var isAvailable: Bool

        var lines: [MetricLine] {
            [("Balance", total), ("Paid", paid), ("Granted", granted)].map { label, amount in
                .values(label: label, values: [
                    MetricValue(number: amount, kind: .dollars, currencyCode: currency == "USD" ? nil : currency)
                ])
            }
        }

        var warning: String? {
            isAvailable ? nil : "Balance unavailable for API calls. Add credits at platform.deepseek.com."
        }
    }

    /// Validate at the API boundary. Prefer USD without adding or converting balances across currencies.
    static func balance(from body: Data) throws -> Balance {
        guard let object = ProviderParse.jsonObject(body),
              let availability = object["is_available"] as? NSNumber,
              CFGetTypeID(availability) == CFBooleanGetTypeID(),
              let infos = object["balance_infos"] as? [[String: Any]], !infos.isEmpty else {
            throw DeepSeekUsageError.invalidResponse
        }
        guard let info = infos.first(where: { $0["currency"] as? String == "USD" })
                ?? infos.first(where: { $0["currency"] as? String == "CNY" }),
              let currency = info["currency"] as? String else {
            throw DeepSeekUsageError.unsupportedCurrency
        }
        guard let total = ProviderParse.number(info["total_balance"]),
              let paid = ProviderParse.number(info["topped_up_balance"]),
              let granted = ProviderParse.number(info["granted_balance"]) else {
            throw DeepSeekUsageError.invalidResponse
        }
        return Balance(currency: currency, total: total, paid: paid, granted: granted,
                       isAvailable: availability.boolValue)
    }
}
