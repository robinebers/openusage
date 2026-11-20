import Foundation

/// `/user/balance` lists one balance per currency the account holds (CNY or USD), each amount a decimal
/// string. Balance is the total: granted and topped-up money together.
enum DeepSeekUsageMapper {
    static func map(_ body: Data) throws -> ProviderUsage {
        guard let balances = ProviderParse.jsonObject(body)?["balance_infos"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse
        }
        let values = try balances.map { balance in
            guard let currency = (balance["currency"] as? String)?.trimmingCharacters(in: .whitespaces).uppercased(),
                  currency.wholeMatch(of: #/[A-Z]{3}/#) != nil,
                  let total = ProviderParse.number(balance["total_balance"]) else {
                throw ProviderError.invalidResponse
            }
            return MetricValue(number: total, kind: .dollars, currencyCode: currency)
        }
        guard !values.isEmpty else {
            throw ProviderError.unavailable("DeepSeek reports no balance for this account.")
        }
        return ProviderUsage(plan: nil, lines: [.values(label: "Balance", values: values)])
    }
}
