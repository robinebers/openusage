import XCTest
@testable import OpenUsage

/// Provider responses carry emails, org ids, and usage, and every read must reach the provider, so the
/// client's session keeps no URL cache, on disk or in memory, with or without a proxy.
final class HTTPClientCacheTests: XCTestCase {
    func testTheSessionCachesNoResponseWithOrWithoutAProxy() {
        let proxy = ProxyConfig(scheme: .socks5, host: "127.0.0.1", port: 1080)
        for (name, proxy) in [("no proxy", nil), ("proxy", proxy)] as [(String, ProxyConfig?)] {
            let configuration = URLSessionHTTPClient.sessionConfiguration(proxy: proxy)
            XCTAssertNil(configuration.urlCache, name)
            XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData, name)
            XCTAssertEqual(configuration.proxyConfigurations.count, proxy == nil ? 0 : 1, name)
        }
    }
}
