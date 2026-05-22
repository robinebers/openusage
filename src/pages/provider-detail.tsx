import { ProviderCard } from "@/components/provider-card"
import type { PluginDisplayState } from "@/lib/plugin-types"
import type { DisplayMode, ResetTimerDisplayMode, TimeFormatMode } from "@/lib/settings"

interface ProviderDetailPageProps {
  plugin: PluginDisplayState | null
  onRetry?: () => void
  displayMode: DisplayMode
  resetTimerDisplayMode: ResetTimerDisplayMode
  timeFormatMode?: TimeFormatMode
  onResetTimerDisplayModeToggle?: () => void
}

export function ProviderDetailPage({
  plugin,
  onRetry,
  displayMode,
  resetTimerDisplayMode,
  timeFormatMode = "auto",
  onResetTimerDisplayModeToggle,
}: ProviderDetailPageProps) {
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
      links={plugin.meta.links}
      showSeparator={false}
      loading={plugin.loading}
      error={plugin.error}
      lines={plugin.data?.lines ?? []}
      skeletonLines={plugin.meta.lines}
      lastManualRefreshAt={plugin.lastManualRefreshAt}
      lastUpdatedAt={plugin.lastUpdatedAt}
      onRetry={onRetry}
      scopeFilter="all"
      displayMode={displayMode}
      resetTimerDisplayMode={resetTimerDisplayMode}
      timeFormatMode={timeFormatMode}
      onResetTimerDisplayModeToggle={onResetTimerDisplayModeToggle}
    />
  )
}
