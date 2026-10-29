import Foundation
import Network
import os
import XCTest
@testable import OpenUsage

final class ProxyConfigTests: XCTestCase {
    private static let providerURL = URL(string: "https://openusage-proxy-test.invalid/usage")!

    func testEachSchemeParsesWithItsDefaultPortAndAnyCredential() throws {
        let cases: [(url: String, expected: ProxyConfig)] = [
            ("socks5://127.0.0.1:10808", ProxyConfig(scheme: .socks5, host: "127.0.0.1", port: 10808)),
            ("socks5://proxy.example.com", ProxyConfig(scheme: .socks5, host: "proxy.example.com", port: 1080)),
            ("http://proxy.example.com", ProxyConfig(scheme: .http, host: "proxy.example.com", port: 80)),
            ("HTTPS://proxy.example.com", ProxyConfig(scheme: .https, host: "proxy.example.com", port: 443)),
            (
                "http://us%40er:p%3Ass@[::1]:8080",
                ProxyConfig(scheme: .http, host: "::1", port: 8080, credential: .init(username: "us@er", password: "p:ss"))
            ),
            (
                "socks5://user@proxy.example.com:1081",
                ProxyConfig(scheme: .socks5, host: "proxy.example.com", port: 1081, credential: .init(username: "user", password: ""))
            )
        ]
        for (url, expected) in cases {
            XCTAssertEqual(try ProxyConfig.parse(Self.file(url: url)), expected, url)
        }
    }

    func testAnAbsentOrDisabledProxyIsOffWithoutAnError() throws {
        let files = [
            "{}",
            #"{"proxy": null}"#,
            #"{"theme": "dark"}"#,
            #"{"proxy": {"enabled": false}}"#,
            #"{"proxy": {"enabled": false, "url": "ftp://nowhere"}}"#
        ]
        for text in files {
            XCTAssertNil(try ProxyConfig.parse(Data(text.utf8)), text)
        }
    }

    func testInvalidConfigThrowsAndItsMessageLeavesOutTheURL() {
        let malformed = [
            "",
            "not json",
            "[]",
            #"{"proxy": "socks5://127.0.0.1:1080"}"#,
            #"{"proxy": {"url": "socks5://127.0.0.1:1080"}}"#,
            #"{"proxy": {"enabled": "true", "url": "socks5://127.0.0.1:1080"}}"#
        ]
        for text in malformed {
            XCTAssertThrowsError(try ProxyConfig.parse(Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? ProxyConfig.ParseError, .invalidJSON, text)
            }
        }
        let badURLs: [String?] = [
            nil,
            "not a url",
            "ftp://alice:s3cret@proxy.example.com",
            "alice:s3cret@proxy.example.com:8080",
            "socks5://alice:s3cret@:1080",
            "http://alice:s3cret@proxy.example.com:70000",
            "http://alice:s3cret@proxy.example.com:0"
        ]
        for url in badURLs {
            XCTAssertThrowsError(try ProxyConfig.parse(Self.file(url: url)), url ?? "no url") { error in
                XCTAssertEqual(error as? ProxyConfig.ParseError, .invalidURL, url ?? "no url")
                let message = error.localizedDescription
                XCTAssertFalse(message.contains("alice") || message.contains("s3cret"), message)
            }
        }
    }

    func testAnHTTPProxyGetsACONNECTForTheProviderHost() async throws {
        let proxy = try await FakeProxy()
        await Self.send(through: proxy.config(.http))
        let first = String(decoding: try proxy.firstBytes(), as: UTF8.self)
        XCTAssertTrue(first.hasPrefix("CONNECT openusage-proxy-test.invalid:443 HTTP/1.1\r\n"), first)
    }

    func testAnHTTPSProxyGetsATLSHandshake() async throws {
        let proxy = try await FakeProxy()
        await Self.send(through: proxy.config(.https))
        XCTAssertEqual(try proxy.firstBytes().first, 0x16, "a TLS handshake record")
    }

    func testASOCKS5ProxyGetsAGreetingThatOffersPasswordAuthOnlyWithACredential() async throws {
        for credential in [nil, ProxyConfig.Credential(username: "alice", password: "s3cret")] {
            let proxy = try await FakeProxy()
            await Self.send(through: proxy.config(.socks5, credential: credential))
            let greeting = try proxy.firstBytes()
            XCTAssertEqual(greeting.first, 0x05, "SOCKS version 5")
            XCTAssertEqual(greeting.dropFirst(2).contains(0x02), credential != nil, "offers username and password auth")
        }
    }

    private static func file(url: String?) -> Data {
        var proxy: [String: Any] = ["enabled": true]
        proxy["url"] = url
        return try! JSONSerialization.data(withJSONObject: ["proxy": proxy])
    }

    private static func send(through proxy: ProxyConfig) async {
        let session = URLSession(configuration: URLSessionHTTPClient.sessionConfiguration(proxy: proxy))
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(for: URLRequest(url: providerURL, timeoutInterval: 5))
    }
}

/// Closes each connection after its first bytes, so the request fails at once instead of waiting out its
/// timeout.
private final class FakeProxy: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let received: OSAllocatedUnfairLock<[Data]>

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let received = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let queue = DispatchQueue(label: "com.robinebers.openusage.tests.fake-proxy")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                if let data { received.withLock { $0.append(data) } }
                connection.cancel()
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
        self.received = received
        port = try XCTUnwrap(listener.port?.rawValue)
    }

    deinit { listener.cancel() }

    func config(_ scheme: ProxyConfig.Scheme, credential: ProxyConfig.Credential? = nil) -> ProxyConfig {
        ProxyConfig(scheme: scheme, host: "127.0.0.1", port: port, credential: credential)
    }

    func firstBytes() throws -> Data {
        try XCTUnwrap(received.withLock { $0.first }, "nothing reached 127.0.0.1:\(port)")
    }
}
