import { ProviderCard } from "@/components/provider-card"
import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"

type PluginDisplayState = {
  meta: PluginMeta
  data: PluginOutput | null
  loading: boolean
  error: string | null
  lastManualRefreshAt: number | null
}

interface OverviewPageProps {
  plugins: PluginDisplayState[]
  onRetryPlugin?: (pluginId: string) => void
}

export function OverviewPage({ plugins, onRetryPlugin }: OverviewPageProps) {
  if (plugins.length === 0) {
    return (
      <div className="text-center text-muted-foreground py-8">
        No providers enabled
      </div>
    )
  }

  return (
    <div>
      {plugins.map((plugin, index) => (
        <ProviderCard
          key={plugin.meta.id}
          name={plugin.meta.name}
          plan={plugin.data?.plan}
          showSeparator={index < plugins.length - 1}
          loading={plugin.loading}
          error={plugin.error}
          lines={plugin.data?.lines ?? []}
          skeletonLines={plugin.meta.lines}
          lastManualRefreshAt={plugin.lastManualRefreshAt}
          onRetry={onRetryPlugin ? () => onRetryPlugin(plugin.meta.id) : undefined}
        />
      ))}
    </div>
  )
}
