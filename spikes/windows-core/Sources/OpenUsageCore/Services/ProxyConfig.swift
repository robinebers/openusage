import Foundation

/// Optional proxy routing for provider HTTP requests.
///
/// Windows spike: proxy support is stubbed out (no `Network` framework). Config file parsing is
/// preserved for future platform transport; `current` is always nil and `apply(to:)` is a no-op.
struct ProxyConfig: Equatable, Sendable {
    enum Scheme: String, Equatable, Sendable {
        case socks5
        case http
        case https

        var defaultPort: UInt16 {
            switch self {
            case .socks5: return 1080
            case .http: return 80
            case .https: return 443
            }
        }
    }

    var scheme: Scheme
    var host: String
    var port: UInt16
    var username: String?
    var password: String?

    static let configPath = "~/.openusage/config.json"

    /// Stub: proxy disabled on Windows spike until HTTP transport seam lands.
    static let current: ProxyConfig? = nil

    static func load(text: String?) -> ProxyConfig? {
        guard let text,
              let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let proxy = root["proxy"] as? [String: Any],
              proxy["enabled"] as? Bool == true,
              let urlString = proxy["url"] as? String,
              let url = URL(string: urlString),
              let schemeRaw = url.scheme?.lowercased(),
              let scheme = Scheme(rawValue: schemeRaw),
              let host = url.host(), !host.isEmpty
        else { return nil }

        return ProxyConfig(
            scheme: scheme,
            host: host,
            port: url.port.flatMap { UInt16(exactly: $0) } ?? scheme.defaultPort,
            username: url.user(percentEncoded: false),
            password: url.password(percentEncoded: false)
        )
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSessionConfiguration {
    /// Windows spike no-op: real proxy wiring deferred to Phase 1 HTTP seam.
    func applyOpenUsageProxy(_ proxy: ProxyConfig?) {
        _ = proxy
    }
}
