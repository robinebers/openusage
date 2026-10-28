import Foundation
import Network

final class LoopbackCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.robinebers.openusage.oauth-callback")
    private let state: String
    private let path: String
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var redirectURI = ""

    private init(listener: NWListener, state: String, path: String) {
        self.listener = listener
        self.state = state
        self.path = path
    }

    static func start(state: String, port: UInt16? = nil, path: String = "/callback") async throws -> LoopbackCallbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: port.map { NWEndpoint.Port(rawValue: $0)! } ?? .any
        )
        let listener = try NWListener(using: parameters)
        let server = LoopbackCallbackServer(listener: listener, state: state, path: path)
        listener.newConnectionHandler = { [weak server] in server?.accept($0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port?.rawValue else {
                        continuation.resume(throwing: LoginError.listenerFailed("No local port was assigned."))
                        return
                    }
                    server.redirectURI = "http://localhost:\(port)\(path)"
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: LoginError.listenerFailed(error.localizedDescription))
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "com.robinebers.openusage.oauth-listener"))
        }
        return server
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func cancel() {
        finish(.failure(LoginError.cancelled))
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffered: Data())
    }

    /// The browser may deliver the request in pieces, so the header is parsed only once its terminator
    /// has arrived; a header cut off by the client or still unterminated at 16 KiB is refused.
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headerLimit - buffered.count) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            let buffered = buffered + (data ?? Data())
            if let end = buffered.range(of: Self.headerTerminator) {
                self.handle(String(decoding: buffered[..<end.lowerBound], as: UTF8.self), connection: connection)
            } else if error == nil, !isComplete, buffered.count < Self.headerLimit {
                self.receive(connection, buffered: buffered)
            } else {
                self.reply(connection, status: 400, body: "Sign-in failed.", result: .failure(LoginError.invalidCallback))
            }
        }
    }

    private static let headerLimit = 16_384
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private func handle(_ request: String, connection: NWConnection) {
        guard let line = request.components(separatedBy: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              line.hasPrefix("GET ") else {
            reply(connection, status: 405, body: "Only GET is supported.", result: .failure(LoginError.invalidCallback))
            return
        }
        guard let url = URL(string: "http://localhost\(target)"), url.path == path else {
            reply(connection, status: 404, body: "Sign-in callback not found.", result: .failure(LoginError.invalidCallback))
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        guard value("state") == state else {
            reply(connection, status: 400, body: "Sign-in state did not match.", result: .failure(LoginError.invalidState))
            return
        }
        if let error = value("error") {
            reply(connection, status: 400, body: "Sign-in failed.", result: .failure(LoginError.authorizationFailed(error)))
            return
        }
        guard let code = value("code"), !code.isEmpty else {
            reply(connection, status: 400, body: "Authorization code was missing.", result: .failure(LoginError.invalidCallback))
            return
        }
        reply(connection, status: 200, body: "Sign-in complete. You may close this page.", result: .success(code))
    }

    private func reply(_ connection: NWConnection, status: Int, body: String, result: Result<String, Error>) {
        finish(result)
        let bodyData = Data("<!doctype html><title>OpenUsage</title><p>\(body)</p>".utf8)
        let response = Data(
            "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n".utf8
        ) + bodyData
        connection.send(content: response, completion: .contentProcessed { [listener] _ in
            connection.cancel()
            listener.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
