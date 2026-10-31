import Foundation
import Network
import XCTest
@testable import OpenUsage

final class OAuthFoundationTests: XCTestCase {
    func testPKCEAppendixBChallenge() {
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testDeviceCodePollerHandlesPendingSlowDownAndSuccess() async throws {
        let results: [DeviceCodePollResult<String>] = [.pending, .slowDown, .complete("token")]
        let index = LockedCounter()
        let sleeps = LockedValues()
        let token = try await DeviceCodePoller.poll(
            interval: 1,
            expiresIn: 100,
            sleep: { seconds in sleeps.append(seconds) },
            request: { results[index.next()] }
        )

        XCTAssertEqual(token, "token")
        XCTAssertEqual(sleeps.values, [1, 6])
    }

    func testDeviceCodeExpiredTokenFails() async {
        do {
            _ = try await DeviceCodePoller.poll(
                interval: 1,
                expiresIn: 100,
                sleep: { _ in },
                request: { .failed("The device code expired.") as DeviceCodePollResult<String> }
            )
            XCTFail("Expected expired token to fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The device code expired.")
        }
    }

    func testLoopbackCallbackAnswersStrayRequestsAndKeepsListeningForTheCode() async throws {
        let server = try await LoopbackCallbackServer.start(state: "expected")
        XCTAssertEqual(URLComponents(string: server.redirectURI)?.host, "localhost")
        let callback = Task { try await server.waitForCode() }
        let callbackURL = server.redirectURI.replacingOccurrences(of: "localhost", with: "127.0.0.1")
        var post = URLRequest(url: URL(string: callbackURL + "?code=ignored&state=expected")!)
        post.httpMethod = "POST"
        let strays = [
            (URLRequest(url: URL(string: callbackURL.replacingOccurrences(of: "/callback", with: "/cancel"))!), 404),
            (URLRequest(url: URL(string: callbackURL + "?code=ignored&state=wrong")!), 400),
            (post, 405)
        ]
        for (request, status) in strays {
            let response = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, status, request.url!.absoluteString)
        }
        let valid = try await URLSession.shared.data(from: URL(string: callbackURL + "?code=accepted&state=expected")!)
        XCTAssertEqual((valid.1 as? HTTPURLResponse)?.statusCode, 200)
        let acceptedCode = try await callback.value
        XCTAssertEqual(acceptedCode, "accepted")
    }

    func testLoopbackCallbackWaitsForTheWholeHeaderBeforeItAnswers() async throws {
        let request = "GET /callback?code=demo&state=expected HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let cuts = [request.range(of: "&state")!.lowerBound, request.range(of: "ected HTTP")!.lowerBound, request.index(before: request.endIndex)]
        for cut in cuts {
            let server = try await LoopbackCallbackServer.start(state: "expected")
            let settled = TestSwitch(false)
            let callback = Task { defer { settled.value = true }; return try await server.waitForCode() }
            let client = try await CallbackClient(server)
            try await client.send(String(request[..<cut]))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(settled.value, "answered the partial header \(String(request[..<cut]).debugDescription)")
            try await client.send(String(request[cut...]))
            let code = try await callback.value
            XCTAssertEqual(code, "demo")
            let reply = await client.reply()
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 "), reply)
            XCTAssertEqual(reply.components(separatedBy: "HTTP/1.1 ").count, 2, "one reply per connection")
        }
    }

    func testLoopbackCallbackRefusesAHeaderCutOffOrPast16KiB() async throws {
        let cutOff = "GET /callback?code=demo&state=expected HTTP/1.1\r\nHost: localhost\r\n"
        let oversized = "GET /callback?code=demo&state=expected&pad=\(String(repeating: "a", count: 20_000)) HTTP/1.1\r\n\r\n"
        for (request, closing) in [(cutOff, true), (oversized, false)] {
            let server = try await LoopbackCallbackServer.start(state: "expected")
            let callback = Task { try await server.waitForCode() }
            let client = try await CallbackClient(server)
            try await client.send(request, closing: closing)
            do {
                let code = try await callback.value
                XCTFail("delivered \(code) from a \(request.count)-byte header\(closing ? " cut off by the client" : "")")
            } catch {
                XCTAssertEqual(error.localizedDescription, LoginError.invalidCallback.localizedDescription)
            }
            let reply = await client.reply()
            if closing { XCTAssertTrue(reply.hasPrefix("HTTP/1.1 400 "), reply) }
        }
    }
}

/// One browser-side TCP connection to the callback server, sending the request in whatever pieces a test wants.
private final class CallbackClient: @unchecked Sendable {
    private let connection: NWConnection

    init(_ server: LoopbackCallbackServer) async throws {
        let port = try XCTUnwrap(URL(string: server.redirectURI)?.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
        connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready: connection.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): connection.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.robinebers.openusage.tests.callback-client"))
        }
    }

    /// Sends one piece; `closing` half-closes the connection after it, the way a client that gives up mid-header does.
    func send(_ piece: String, closing: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(piece.utf8), contentContext: closing ? .finalMessage : .defaultMessage, isComplete: closing,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            )
        }
    }

    /// Everything the server sent before it closed the connection.
    func reply() async -> String {
        var received = Data()
        while true {
            let (data, done) = await withCheckedContinuation { (continuation: CheckedContinuation<(Data, Bool), Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    continuation.resume(returning: (data ?? Data(), isComplete || error != nil))
                }
            }
            received += data
            if done { return String(decoding: received, as: UTF8.self) }
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}

private final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval] = []
    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(value)
    }
}
