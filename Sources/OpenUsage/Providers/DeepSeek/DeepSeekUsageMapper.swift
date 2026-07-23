import Foundation

enum DeepSeekUsageMapper {
    static func balanceLines(from data: Data) -> [MetricLine] {
        guard let json = ProviderParse.jsonObject(data) else { return [] }
        guard let balanceInfos = json["balance_infos"] as? [[String: Any]], !balanceInfos.isEmpty else { return [] }

        var usdBalance: Double?
        var cnyBalance: Double?
        for info in balanceInfos {
            guard let currency = info["currency"] as? String,
                  let totalStr = info["total_balance"] as? String,
                  let total = Double(totalStr) else { continue }
            if currency == "USD" {
                usdBalance = total
                break
            }
            if currency == "CNY" {
                cnyBalance = total
            }
        }

        let balance = usdBalance ?? cnyBalance
        guard let balance = balance else { return [] }

        var lines: [MetricLine] = []
        lines.append(.values(
            label: "Balance",
            values: [MetricValue(number: max(0, balance), kind: .dollars)]
        ))
        return lines
    }
}
