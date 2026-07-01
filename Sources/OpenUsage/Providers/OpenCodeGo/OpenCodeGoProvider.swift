import Foundation

@MainActor
final class OpenCodeGoProvider: ProviderRuntime {
    let provider = Provider(
        id: "opencodego",
        displayName: "OpenCode Go",
        icon: .providerMark("opencodego")
    )

    let usageClient: OpenCodeGoUsageClient
    let now: @Sendable () -> Date

    init(
        usageClient: OpenCodeGoUsageClient = OpenCodeGoUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.usageClient = usageClient
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(
                id: "opencodego.kimiForCoding",
                provider: provider,
                title: "Kimi for Coding",
                metricLabel: "Kimi for Coding"
            ),
            .percent(
                id: "opencodego.glm",
                provider: provider,
                title: "GLM",
                metricLabel: "GLM"
            )
        ]
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let data = try await usageClient.loadUsagePayload()
            let lines = OpenCodeGoUsageMapper.map(data)
            return ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now())
        } catch let error as OpenCodeGoUsageError {
            return ProviderSnapshot.error(provider: provider, error: error)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: OpenCodeGoUsageError.connectionFailed)
        }
    }
}
