import Foundation

struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 15
}

struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// The `Date` header as an instant, `nil` when it is absent or not an HTTP date.
    var date: Date? {
        header("Date").flatMap { Self.httpDateFormatter.date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The wait a `Retry-After` header names, in seconds from `now`: delay-seconds or an HTTP date.
    /// `nil` when the header is absent or unreadable, or names no wait at all.
    func retryAfter(now: Date = Date()) -> TimeInterval? {
        guard let value = header("Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        let seconds = TimeInterval(value) ?? Self.httpDateFormatter.date(from: value).map { $0.timeIntervalSince(now) }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

struct URLSessionHTTPClient: HTTPClient {
    private static let session = URLSession(configuration: .default)

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let start = ContinuousClock.now
        let (data, response) = try await Self.session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        let result = HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        AppLog.debug(.http, Self.diagnostic(for: request, response: result, duration: ContinuousClock.now - start))
        return result
    }

    /// The one line the transport logs per exchange: method, host and path, status, and duration.
    /// It never reads the query, the headers, or either body, so a credential in any of them (an
    /// `Authorization` header, Cursor's PKCE verifier in the poll query, a token echoed in an error
    /// body) cannot reach the log.
    static func diagnostic(for request: HTTPRequest, response: HTTPResponse, duration: Duration) -> String {
        let milliseconds = Int((duration / .milliseconds(1)).rounded())
        let endpoint = (request.url.host() ?? "") + request.url.path()
        return "\(request.method) \(endpoint) -> \(response.statusCode) (\(milliseconds) ms)"
    }
}

enum HTTPClientError: Error, LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "Invalid HTTP response."
    }
}
