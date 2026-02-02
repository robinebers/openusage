import { ProviderCard } from "@/components/provider-card"
import type { PluginMeta, PluginOutput } from "@/lib/plugin-types"

type PluginDisplayState = {
  meta: PluginMeta
  data: PluginOutput | null
  loading: boolean
  error: string | null
  lastManualRefreshAt: number | null
}

interface ProviderDetailPageProps {
  plugin: PluginDisplayState | null
  onRetry?: () => void
}

export function ProviderDetailPage({ plugin, onRetry }: ProviderDetailPageProps) {
  if (!plugin) {
    return (
      <div className="text-center text-muted-foreground py-8">
        Provider not found
      </div>
    )
  }

  return (
    <ProviderCard
      name={plugin.meta.name}
      plan={plugin.data?.plan}
      showSeparator={false}
      loading={plugin.loading}
      error={plugin.error}
      lines={plugin.data?.lines ?? []}
      skeletonLines={plugin.meta.lines}
      lastManualRefreshAt={plugin.lastManualRefreshAt}
      onRetry={onRetry}
    />
  )
}
