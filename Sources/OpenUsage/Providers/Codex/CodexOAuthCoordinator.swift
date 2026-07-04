import AppKit
import CryptoKit
import Foundation
import Network
import Observation

enum CodexOAuthError: Error, LocalizedError, Equatable {
    case alreadyInProgress
    case callbackPortUnavailable
    case callbackTimedOut
    case callbackCancelled
    case invalidCallback
    case stateMismatch
    case missingCode

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            "A Codex login is already in progress."
        case .callbackPortUnavailable:
            "Codex login could not start because localhost port 1455 is already in use."
        case .callbackTimedOut:
            "Codex login timed out. Try again."
        case .callbackCancelled:
            "Codex login was cancelled."
        case .invalidCallback:
            "Codex login returned an invalid callback."
        case .stateMismatch:
            "Codex login returned a mismatched state. Try again."
        case .missingCode:
            "Codex login did not return an authorization code."
        }
    }
}

@MainActor
@Observable
final class CodexOAuthCoordinator {
    enum Status: Equatable {
        case idle
        case waiting
        case failed(String)
        case succeeded
    }

    private static let callbackPort: UInt16 = 1455
    private static let callbackPath = "/auth/callback"
    private static let timeoutSeconds: TimeInterval = 5 * 60

    private let accountStore: CodexAccountStore
    private let usageClient: CodexUsageClient
    private var server: CodexOAuthCallbackServer?
    private var task: Task<Void, Never>?

    var status: Status = .idle
    var isWaiting: Bool { status == .waiting }

    init(accountStore: CodexAccountStore, usageClient: CodexUsageClient = CodexUsageClient()) {
        self.accountStore = accountStore
        self.usageClient = usageClient
    }

    func start(onAccountAdded: @escaping @MainActor () -> Void) {
        guard task == nil else {
            status = .failed(CodexOAuthError.alreadyInProgress.localizedDescription)
            return
        }

        let state = Self.randomURLSafeString(byteCount: 32)
        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.codeChallenge(for: verifier)
        let redirectURI = "http://localhost:\(Self.callbackPort)\(Self.callbackPath)"
        guard let authorizeURL = Self.authorizeURL(
            state: state,
            codeChallenge: challenge,
            redirectURI: redirectURI
        ) else {
            status = .failed(CodexOAuthError.invalidCallback.localizedDescription)
            return
        }

        status = .waiting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let callback = try await self.waitForCallback(state: state)
                let response = try await self.usageClient.exchangeAuthorizationCode(
                    code: callback.code,
                    redirectURI: redirectURI,
                    codeVerifier: verifier
                )
                var auth = CodexAuth(
                    tokens: CodexTokens(
                        accessToken: response.accessToken,
                        refreshToken: response.refreshToken,
                        idToken: response.idToken,
                        accountID: response.accountID
                    ),
                    lastRefresh: OpenUsageISO8601.string(from: Date()),
                    apiKey: nil
                )
                if auth.tokens?.accountID == nil,
                   let accountID = ProviderParse.jwtPayload(response.idToken ?? "")?["https://api.openai.com/auth"] as? [String: Any],
                   let value = accountID["chatgpt_account_id"] as? String {
                    auth.tokens?.accountID = value
                }
                _ = try self.accountStore.saveManagedAuth(auth)
                self.status = .succeeded
                onAccountAdded()
            } catch {
                if !(error is CancellationError) {
                    self.status = .failed(error.localizedDescription)
                    AppLog.warn(LogTag.auth("codex"), "Codex OAuth failed: \(error.localizedDescription)")
                }
            }
            self.stopServer()
            self.task = nil
        }

        NSWorkspace.shared.open(authorizeURL)
    }

    func cancel() {
        task?.cancel()
        task = nil
        stopServer()
        status = .idle
    }

    private func waitForCallback(state: String) async throws -> CodexOAuthCallback {
        let server = CodexOAuthCallbackServer(port: Self.callbackPort, expectedState: state)
        self.server = server
        do {
            return try await withThrowingTaskGroup(of: CodexOAuthCallback.self) { group in
                group.addTask { try await server.startAndWait() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                    throw CodexOAuthError.callbackTimedOut
                }
                guard let result = try await group.next() else {
                    throw CodexOAuthError.invalidCallback
                }
                group.cancelAll()
                return result
            }
        } catch {
            stopServer()
            throw error
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
    }

    private static func authorizeURL(state: String, codeChallenge: String, redirectURI: String) -> URL? {
        var components = URLComponents(url: CodexUsageClient.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexUsageClient.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "openusage"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

struct CodexOAuthCallback: Sendable, Equatable {
    var code: String
}

final class CodexOAuthCallbackServer: @unchecked Sendable {
    private let port: UInt16
    private let expectedState: String
    private let queue = DispatchQueue(label: "openusage.codex-oauth")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<CodexOAuthCallback, Error>?

    init(port: UInt16, expectedState: String) {
        self.port = port
        self.expectedState = expectedState
    }

    func startAndWait() async throws -> CodexOAuthCallback {
        try start()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            self.stop()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CodexOAuthError.callbackCancelled)
        }
    }

    private func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!
        )
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            throw CodexOAuthError.callbackPortUnavailable
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let result = self.parse(head: head)
            self.respond(result: result, over: connection)
            if case .success(let callback) = result {
                let continuation = self.continuation
                self.continuation = nil
                self.listener?.cancel()
                self.listener = nil
                continuation?.resume(returning: callback)
            } else if case .failure(let error) = result {
                let continuation = self.continuation
                self.continuation = nil
                self.listener?.cancel()
                self.listener = nil
                continuation?.resume(throwing: error)
            }
        }
    }

    private func parse(head: String) -> Result<CodexOAuthCallback, CodexOAuthError> {
        guard let requestLine = head.split(separator: "\r\n", maxSplits: 1).first else {
            return .failure(.invalidCallback)
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://localhost\(parts[1])"),
              components.path == "/auth/callback"
        else {
            return .failure(.invalidCallback)
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard items["state"] == expectedState else { return .failure(.stateMismatch) }
        guard let code = items["code"], !code.isEmpty else { return .failure(.missingCode) }
        return .success(CodexOAuthCallback(code: code))
    }

    private func respond(result: Result<CodexOAuthCallback, CodexOAuthError>, over connection: NWConnection) {
        let message: String
        switch result {
        case .success:
            message = "Codex login complete. You can return to OpenUsage."
        case .failure:
            message = "Codex login failed. You can return to OpenUsage and try again."
        }
        let body = Data("""
        <!doctype html><html><body><p>\(message)</p></body></html>
        """.utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
