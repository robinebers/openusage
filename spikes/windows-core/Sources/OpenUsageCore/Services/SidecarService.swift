import Foundation

/// In-process provider registry for the sidecar executable.
@MainActor
public final class SidecarService {
    private struct Entry {
        let id: String
        let runtime: any ProviderRuntime
        var credentialsFound: Bool
        var snapshot: ProviderSnapshot?
    }

    private var entries: [Entry]

    public init() {
        let runtimes: [(String, any ProviderRuntime)] = [
            ("claude", ClaudeProvider()),
            ("codex", CodexProvider()),
            ("cursor", CursorProvider()),
            ("grok", GrokProvider()),
            ("openrouter", OpenRouterProvider()),
            ("zai", ZAIProvider())
        ]
        entries = runtimes.map { id, runtime in
            Entry(id: id, runtime: runtime, credentialsFound: false, snapshot: nil)
        }
    }

    public func bootstrap() async {
        for index in entries.indices {
            entries[index].credentialsFound = await entries[index].runtime.hasLocalCredentials()
        }
        await refresh(providerID: "all")
    }

    public func handle(_ request: SidecarRequest) async throws -> SidecarResponse {
        switch request.op {
        case "ping":
            return .pong()
        case "snapshot":
            return .snapshot(snapshotDTOs())
        case "refresh":
            let target = request.provider ?? "all"
            await refresh(providerID: target)
            return .snapshot(snapshotDTOs())
        default:
            throw SidecarIPCError.unknownOperation(request.op)
        }
    }

    private func snapshotDTOs() -> [SidecarProviderDTO] {
        entries.map { entry in
            SidecarSnapshotMapper.makeProviderDTO(
                id: entry.id,
                displayName: entry.runtime.provider.displayName,
                credentialsFound: entry.credentialsFound,
                snapshot: entry.snapshot
            )
        }
    }

    private func refresh(providerID: String) async {
        if providerID == "all" {
            for index in entries.indices where entries[index].credentialsFound {
                entries[index].snapshot = await entries[index].runtime.refresh()
            }
            return
        }

        guard let index = entries.firstIndex(where: { $0.id == providerID }) else {
            return
        }
        guard entries[index].credentialsFound else {
            return
        }
        entries[index].snapshot = await entries[index].runtime.refresh()
    }
}
