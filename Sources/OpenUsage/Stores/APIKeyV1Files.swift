import Foundation

/// The OpenRouter and Z.ai keys 0.7.x saved in OpenUsage's own config folder, which this build imports
/// once and never changes, so a downgrade to 0.7.x finds them as it left them.
enum APIKeyV1Files {
    static let importedKey = "openusage.apiKeyFiles.v1.imported"

    /// Adds each saved key as an account of a provider that has none yet, once Add Account's usage read
    /// accepts it. A provider is done once its outcome is final, so a key the user removes stays removed;
    /// a check that could not reach the provider is tried again on the next launch.
    @MainActor
    static func importOnce(
        into accounts: AccountStore,
        defaults: UserDefaults = .standard,
        home: URL = .homeDirectory,
        http: any HTTPClient = URLSessionHTTPClient()
    ) async {
        for (kind, file) in [(ProviderKind.openrouter, "openrouter.json"), (.zai, "zai.json")] {
            let doneKey = "\(importedKey).\(kind.rawValue)"
            guard !defaults.bool(forKey: doneKey) else { continue }
            if !accounts.accounts.contains(where: { $0.kind == kind }),
               let key = key(at: home.appending(path: ".config/openusage/\(file)")) {
                let (input, continuation) = AsyncStream.makeStream(of: String.self)
                continuation.yield(key)
                continuation.finish()
                do {
                    let result = try await APIKeyLogin(kind: kind, http: http).login(prompt: { _ in }, pastedCode: input)
                    if !accounts.accounts.contains(where: { $0.kind == kind }) {
                        accounts.add(kind: kind, label: result.label, credential: result.credential)
                        AppLog.notice(.config, "imported the \(kind.displayName) key 0.7.x saved in \(file)")
                    }
                } catch let error where isTransient(error) {
                    AppLog.warn(.config, "could not check the \(kind.displayName) key 0.7.x saved in \(file), trying again next launch: \(error.localizedDescription)")
                    continue
                } catch {
                    AppLog.warn(.config, "skipped the \(kind.displayName) key 0.7.x saved in \(file): \(error.localizedDescription)")
                }
            }
            defaults.set(true, forKey: doneKey)
        }
    }

    /// Being offline or rate-limited, as the refresh loop classes it, or a timeout or server error.
    private static func isTransient(_ error: Error) -> Bool {
        if case ProviderError.requestFailed(let status) = error { return status == 408 || status >= 500 }
        return RefreshFailure(error: error).kind != .refused
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
