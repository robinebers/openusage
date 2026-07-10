import Foundation

/// Headless Phase 2 verification harness — prints per-provider credential/refresh status without secrets.
public enum Phase2E2EHarness {
    @MainActor
    public static func run() async {
        let providers: [(String, any ProviderRuntime)] = [
            ("claude", ClaudeProvider()),
            ("codex", CodexProvider()),
            ("cursor", CursorProvider()),
            ("grok", GrokProvider()),
            ("openrouter", OpenRouterProvider()),
            ("zai", ZAIProvider())
        ]

        print("OpenUsage Phase 2 e2e harness")
        print("platform=windows")

        for (name, provider) in providers {
            let creds = await provider.hasLocalCredentials()
            print("provider=\(name) credentialsFound=\(creds ? "yes" : "no")")
            guard creds else { continue }

            let snapshot = await provider.refresh()
            if let category = snapshot.errorCategory {
                let message: String
                if let errorLine = snapshot.lines.first(where: { $0.isError }) {
                    switch errorLine {
                    case .badge(_, let text, _, _):
                        message = text
                    default:
                        message = "unknown"
                    }
                } else {
                    message = "unknown"
                }
                print("provider=\(name) refresh=failure errorCategory=\(category.rawValue) message=\(message)")
            } else {
                print("provider=\(name) refresh=success metricLines=\(snapshot.lines.count) plan=\(snapshot.plan ?? "nil")")
            }
        }
    }
}
