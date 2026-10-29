import Foundation
import Network

struct ProxyConfig: Equatable, Sendable {
    enum Scheme: String, Sendable {
        case socks5
        case http
        case https

        var defaultPort: UInt16 {
            switch self {
            case .socks5: 1080
            case .http: 80
            case .https: 443
            }
        }
    }

    struct Credential: Equatable, Sendable {
        var username: String
        var password: String
    }

    /// Error text never quotes the URL, not even its scheme. A password can sit anywhere in it, and
    /// `user:pass@host` without a scheme parses its user name as the scheme.
    enum ParseError: LocalizedError, Equatable {
        case invalidJSON
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                #"~/.openusage/config.json is not valid JSON in the form {"proxy": {"enabled": true, "url": "socks5://host:port"}}"#
            case .invalidURL:
                "proxy.url in ~/.openusage/config.json must be socks5://, http://, or https://, then a host and an optional port"
            }
        }
    }

    var scheme: Scheme
    var host: String
    var port: UInt16
    var credential: Credential?

    static func load() -> ProxyConfig? {
        do {
            let proxy = try parse(Data(contentsOf: URL.homeDirectory.appending(path: ".openusage/config.json")))
            if let proxy {
                AppLog.notice(.config, "proxy on: \(proxy.scheme.rawValue)://\(proxy.host):\(proxy.port)")
            }
            return proxy
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            AppLog.error(.config, "proxy off: \(error.localizedDescription)")
            return nil
        }
    }

    static func parse(_ data: Data) throws -> ProxyConfig? {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { throw ParseError.invalidJSON }
        guard let proxy = file.proxy, proxy.enabled else { return nil }
        guard let url = proxy.url.flatMap(URL.init(string:)),
              let scheme = url.scheme.flatMap({ Scheme(rawValue: $0.lowercased()) }),
              let host = url.host(), !host.isEmpty,
              let port = UInt16(exactly: url.port ?? Int(scheme.defaultPort)), port > 0
        else { throw ParseError.invalidURL }
        let credential = url.user(percentEncoded: false).map {
            Credential(username: $0, password: url.password(percentEncoded: false) ?? "")
        }
        return ProxyConfig(scheme: scheme, host: host, port: port, credential: credential)
    }

    var proxyConfiguration: ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
        var configuration = switch scheme {
        case .socks5: ProxyConfiguration(socksv5Proxy: endpoint)
        case .http: ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .https: ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        }
        if let credential {
            configuration.applyCredential(username: credential.username, password: credential.password)
        }
        return configuration
    }

    private struct File: Decodable {
        struct Proxy: Decodable {
            var enabled: Bool
            var url: String?
        }

        var proxy: Proxy?
    }
}
