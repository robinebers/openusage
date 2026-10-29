import Foundation

/// The OpenRouter and Z.ai keys 0.7.x saved in OpenUsage's own config folder, which this build imports
/// once and never changes, so a downgrade to 0.7.x finds them as it left them.
enum APIKeyV1Files {
    static let importedKey = "openusage.apiKeyFiles.v1.imported"

    /// Adds each saved key as an account of a provider that has none yet, once Add Account's usage read
    /// accepts it. Later launches import nothing, so a key the user removes stays removed.
    @MainActor
    static func importOnce(
        into accounts: AccountStore,
        defaults: UserDefaults = .standard,
        home: URL = .homeDirectory,
        http: any HTTPClient = URLSessionHTTPClient()
    ) async {
    }

    /// The key 0.7.x's key editor wrote, as `{"apiKey": "…"}`.
    private static func key(at url: URL) -> String? {
        do {
            let key = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url)).apiKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            AppLog.warn(.config, "cannot read \(url.lastPathComponent), leaving it out: \(error.localizedDescription)")
            return nil
        }
    }

    private struct Saved: Decodable {
        let apiKey: String
    }
}
