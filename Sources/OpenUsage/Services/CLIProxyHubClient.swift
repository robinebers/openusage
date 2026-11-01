import Foundation

/// The two management endpoints OpenUsage calls on a CLIProxyAPI hub: the login listing, and
/// `api-call`, which sends a request upstream with the hub's own token in place of `$TOKEN$`. Every
/// call goes through the hub's key gate. Neither the key nor a body is ever logged.
struct CLIProxyHubClient: Sendable {
    static let tokenPlaceholder = "$TOKEN$"

    let http: any HTTPClient
    let gate: CLIProxyHubGate

    func logins(hubID: UUID, url: URL, key: String) async throws -> [HubLogin] {
        let response = try await management("GET", "auth-files", hubID: hubID, url: url, key: key)
        do {
            return try HubLogin.listing(from: response.body)
        } catch {
            AppLog.error(LogTag.auth("cliproxy"), "\(CLIProxyHub.host(of: url)) sent a login listing OpenUsage can't read")
            throw ProviderError.unavailable("The CLIProxyAPI hub at \(CLIProxyHub.host(of: url)) sent a login list OpenUsage can't read.")
        }
    }

    /// Sends `request` through the hub as the linked login and returns the upstream answer, so a
    /// provider client reads it as if it had called the provider itself.
    func call(_ request: HTTPRequest, via link: HubLink, key: String, upstream: String) async throws -> HTTPResponse {
        var payload: [String: Any] = [
            "auth_index": link.authIndex,
            "method": request.method,
            "url": request.url.absoluteString,
            "header": request.headers
        ]
        if let body = request.body { payload["data"] = String(decoding: body, as: UTF8.self) }
        let response = try await management(
            "POST", "api-call", hubID: link.hubID, url: link.hubURL, key: key,
            body: try JSONSerialization.data(withJSONObject: payload), timeout: request.timeout + 10, upstream: upstream
        )
        guard let upstreamResponse = Self.unwrap(response.body) else {
            AppLog.error(LogTag.auth("cliproxy"), "\(link.host) sent an api-call answer OpenUsage can't read")
            throw ProviderError.invalidResponse
        }
        return upstreamResponse
    }

    /// The upstream response inside an `api-call` envelope: `{status_code, header: {name: [value]}, body}`.
    static func unwrap(_ body: Data) -> HTTPResponse? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(Envelope.self, from: body) else { return nil }
        var headers: [String: String] = [:]
        for (name, values) in envelope.header ?? [:] where !values.isEmpty {
            headers[name.lowercased()] = values.joined(separator: ", ")
        }
        return HTTPResponse(statusCode: envelope.statusCode, headers: headers, body: Data((envelope.body ?? "").utf8))
    }

    private struct Envelope: Decodable {
        let statusCode: Int
        let header: [String: [String]]?
        let body: String?
    }

    private func management(
        _ method: String,
        _ path: String,
        hubID: UUID,
        url: URL,
        key: String,
        body: Data? = nil,
        timeout: TimeInterval = 15,
        upstream: String? = nil
    ) async throws -> HTTPResponse {
        var headers = ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        if body != nil { headers["Content-Type"] = "application/json" }
        let request = HTTPRequest(
            method: method, url: url.appending(path: "v0/management/\(path)"), headers: headers, body: body, timeout: timeout
        )
        let host = CLIProxyHub.host(of: url)
        let response: HTTPResponse
        do {
            response = try await gate.send(hub: hubID, host: host, key: key) { [http] in try await http.send(request) }
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.warn(LogTag.auth("cliproxy"), "\(host) \(path) unreachable: \(error.localizedDescription)")
            throw ProviderError.unreachable("Can’t reach the CLIProxyAPI hub at \(host).")
        }
        guard let refusal = HubRefusal(response) else { return response }
        AppLog.error(
            LogTag.auth("cliproxy"),
            "\(host) \(path) -> HTTP \(response.statusCode) (\(refusal)), hub \(response.header("X-CPA-VERSION") ?? "version unknown")"
        )
        throw refusal.error(host: host, upstream: upstream)
    }
}

/// A management answer that isn't a success, sorted by what the user can do about it.
enum HubRefusal: Equatable {
    case keyRejected
    case banned
    case remoteManagementOff
    case managementOff
    case loginMissing
    case noToken
    case upstreamUnreachable
    case failed(Int)

    init?(_ response: HTTPResponse) {
        guard !(200..<300).contains(response.statusCode) else { return nil }
        let message = (ProviderParse.jsonObject(response.body)?["error"] as? String ?? "").lowercased()
        switch response.statusCode {
        case 401: self = .keyRejected
        case 403 where message.hasPrefix("ip banned"): self = .banned
        case 403 where message.contains("remote management disabled"): self = .remoteManagementOff
        case 404: self = .managementOff
        case 400 where message.contains("auth credential not found"): self = .loginMissing
        case 400 where message.contains("token"): self = .noToken
        case 502: self = .upstreamUnreachable
        default: self = .failed(response.statusCode)
        }
    }

    /// A refusal that a repeat would turn into another strike toward the hub's IP ban.
    var closesGate: Bool { self == .keyRejected || self == .banned }

    func error(host: String, upstream: String?) -> ProviderError {
        switch self {
        case .keyRejected:
            .unavailable("The CLIProxyAPI hub at \(host) rejected the management key. Replace it in Accounts.")
        case .banned:
            .unavailable("The CLIProxyAPI hub at \(host) blocked this Mac after too many wrong keys. Wait 30 minutes, then replace the management key in Accounts.")
        case .remoteManagementOff:
            .unavailable("The CLIProxyAPI hub at \(host) only allows management from its own machine. Turn on allow-remote in its config.")
        case .managementOff:
            .unavailable("The CLIProxyAPI hub at \(host) has its management API turned off. Set a management key in its config.")
        case .loginMissing:
            .unavailable("This login is no longer on the CLIProxyAPI hub at \(host).")
        case .noToken:
            .unavailable("The CLIProxyAPI hub at \(host) has no working sign-in for this login. Sign it in again on the hub.")
        case .upstreamUnreachable:
            .unreachable("The CLIProxyAPI hub at \(host) couldn’t reach \(upstream ?? "the provider").")
        case .failed(let status):
            .unavailable("The CLIProxyAPI hub at \(host) answered with an error (HTTP \(status)).")
        }
    }
}

/// Keeps a wrong management key to one strike per hub. CLIProxyAPI bans an IP for 30 minutes after five
/// wrong keys, and every mirrored account refreshes at once, so a hub's calls go one at a time: when the
/// hub rejects the key, or has banned this Mac, the calls waiting behind fail without being sent, and
/// nothing more goes to that hub with that key. A refusal holds only the key it was sent with, so a late
/// answer to the replaced key never stops the new one.
actor CLIProxyHubGate {
    private var busy: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var refused: [UUID: (key: String, error: ProviderError)] = [:]

    func send(hub: UUID, host: String, key: String, _ request: @Sendable () async throws -> HTTPResponse) async throws -> HTTPResponse {
        if let error = refusal(of: hub, key: key) { throw error }
        if busy.insert(hub).inserted == false {
            await withCheckedContinuation { waiters[hub, default: []].append($0) }
        }
        defer { handOff(hub) }
        if let error = refusal(of: hub, key: key) { throw error }
        let response = try await request()
        if let refusal = HubRefusal(response), refusal.closesGate {
            let error = refusal.error(host: host, upstream: nil)
            refused[hub] = (key, error)
            AppLog.error(LogTag.auth("cliproxy"), "\(host) \(refusal); not calling it again until its key is replaced")
            throw error
        }
        return response
    }

    /// Lets the hub be called again: its key was replaced, or the hub was removed.
    func reopen(_ hub: UUID) {
        refused[hub] = nil
    }

    private func refusal(of hub: UUID, key: String) -> ProviderError? {
        guard let refused = refused[hub], refused.key == key else { return nil }
        return refused.error
    }

    private func handOff(_ hub: UUID) {
        guard var queue = waiters[hub], !queue.isEmpty else {
            busy.remove(hub)
            waiters[hub] = nil
            return
        }
        let next = queue.removeFirst()
        waiters[hub] = queue
        next.resume()
    }
}

/// The HTTP client of an account mirrored from a hub while hubs are off: it reads no key and sends nothing.
struct HubOff: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw ProviderError.unavailable(CLIProxyHub.offMessage)
    }
}

/// The HTTP client of an account mirrored from a hub: every request its unchanged provider client
/// sends goes out through the hub's `api-call`, as the linked login.
struct HubTunnel: HTTPClient {
    let link: HubLink
    let kind: ProviderKind
    let vault: any CredentialVault
    let client: CLIProxyHubClient

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard case .apiKey(let key) = try vault.load(link.hubID) else {
            AppLog.error(LogTag.auth("cliproxy"), "\(link.host) has no stored management key")
            throw ProviderError.unavailable("The management key for the CLIProxyAPI hub at \(link.host) is missing. Replace it in Accounts.")
        }
        return try await client.call(request, via: link, key: key, upstream: kind.displayName)
    }
}
