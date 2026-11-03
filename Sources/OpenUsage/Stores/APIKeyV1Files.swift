import Foundation

/// The OpenRouter and Z.ai keys 0.7.x saved in OpenUsage's own config folder, which this build imports
/// once and never changes, so a downgrade to 0.7.x finds them as it left them.
enum APIKeyV1Files {
    static let importedKey = "openusage.apiKeyFiles.v1.imported"
    static let developmentBundleIdentifier = "com.robinebers.openusage.dev"

    /// Adds each saved key as an account of a provider that has none yet and that 0.7.x had on, once a usage
    /// read accepts it. A provider is done once its key is saved, refused, or left off, so a key the user
    /// removes stays removed and a provider the user turned off stays off; a
    /// check or Keychain write that fails for any other reason is tried again on the next launch. The
    /// development build leaves the keys alone, as it does the installed app's settings.
    @MainActor
    static func importOnce(
        into accounts: AccountStore,
        defaults: UserDefaults = .standard,
        home: URL = .homeDirectory,
        http: any HTTPClient = URLSessionHTTPClient(),
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) async {
        guard bundleIdentifier != developmentBundleIdentifier else { return }
        for (kind, file) in [(ProviderKind.openrouter, "openrouter.json"), (.zai, "zai.json")] {
            let doneKey = "\(importedKey).\(kind.rawValue)"
            guard !defaults.bool(forKey: doneKey) else { continue }
            if !wasTurnedOff(kind, in: defaults),
               !accounts.accounts.contains(where: { $0.kind == kind }),
               let key = key(at: home.appending(path: ".config/openusage/\(file)")) {
                let runtime = AccountProviderRuntime(account: Account(kind: kind, label: kind.displayName), vault: accounts.credentialVault, http: http)
                do {
                    try await runtime.readSnapshot(using: .apiKey(key))
                    if !accounts.accounts.contains(where: { $0.kind == kind }) {
                        let account = accounts.add(kind: kind, label: kind.displayName, credential: .apiKey(key))
                        guard accounts.accounts.contains(where: { $0.id == account.id }) else {
                            AppLog.warn(.config, "could not save the \(kind.displayName) key 0.7.x saved in \(file), trying again next launch")
                            continue
                        }
                        AppLog.notice(.config, "imported the \(kind.displayName) key 0.7.x saved in \(file)")
                    }
                } catch ProviderError.keyRejected(let message) {
                    AppLog.warn(.config, "skipped the \(kind.displayName) key 0.7.x saved in \(file): \(message)")
                } catch {
                    AppLog.warn(.config, "could not check the \(kind.displayName) key 0.7.x saved in \(file), trying again next launch: \(error.localizedDescription)")
                    continue
                }
            }
            defaults.set(true, forKey: doneKey)
        }
    }

    /// 0.7.x saved the providers it had on, or, before that list existed, the ones the user turned off.
    private static func wasTurnedOff(_ kind: ProviderKind, in defaults: UserDefaults) -> Bool {
        let isKind = { (id: String) in id.prefix { $0 != "@" } == kind.rawValue }
        if let enabled = defaults.stringArray(forKey: "openusage.enabledProviders.v1") {
            return !enabled.contains(where: isKind)
        }
        return defaults.stringArray(forKey: "openusage.disabledProviders.v1")?.contains(where: isKind) ?? false
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
