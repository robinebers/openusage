import Foundation

struct OpenCodeGoUsageClient: Sendable {
    static let localUsageFiles = [
        "~/.config/opencodego/usage.json",
        "~/.config/opencode/usage.json",
        "~/.opencodego/usage.json",
        "~/Library/Application Support/opencodego/usage.json",
        "~/Library/Application Support/OpenCodeGo/usage.json"
    ]
    static let usageEndpointEnvs = ["OPENCODEGO_USAGE_ENDPOINT", "OPENCODE_GO_USAGE_ENDPOINT"]

    var files: TextFileAccessing
    var environment: EnvironmentReading
    var http: any HTTPClient

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        http: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.files = files
        self.environment = environment
        self.http = http
    }

    /// Load usage payload from the safest local source first (file), then a user-configured local endpoint.
    /// This intentionally avoids credentials and prefers data the OpenCode Go process already writes locally.
    func loadUsagePayload() async throws -> Data {
        if let localData = loadUsageFromLocalFile() {
            return localData
        }
        if let endpoint = usageEndpoint() {
            return try await loadUsageFromEndpoint(endpoint)
        }
        throw OpenCodeGoUsageError.noUsageSource
    }

    private func loadUsageFromLocalFile() -> Data? {
        for path in Self.localUsageFiles {
            guard files.exists(path), let text = try? files.readText(path) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            return data
        }
        return nil
    }

    private func usageEndpoint() -> URL? {
        for name in Self.usageEndpointEnvs {
            if let raw = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty,
               let url = URL(string: raw) {
                return url
            }
        }
        return nil
    }

    private func loadUsageFromEndpoint(_ url: URL) async throws -> Data {
        let response = try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: ["Accept": "application/json"],
            timeout: 10
        ))

        if response.statusCode == 401 || response.statusCode == 403 {
            throw OpenCodeGoUsageError.requestFailed(response.statusCode)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw OpenCodeGoUsageError.requestFailed(response.statusCode)
        }
        guard !response.body.isEmpty else { throw OpenCodeGoUsageError.invalidResponse }
        return response.body
    }
}
