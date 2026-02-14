import { ProviderCard } from "@/components/provider-card"
import type { PluginDisplayState } from "@/lib/plugin-types"
import type { DisplayMode, ResetTimerDisplayMode } from "@/lib/settings"

interface OverviewPageProps {
  plugins: PluginDisplayState[]
  onRetryPlugin?: (pluginId: string) => void
  displayMode: DisplayMode
  resetTimerDisplayMode: ResetTimerDisplayMode
  onResetTimerDisplayModeToggle?: () => void
  accountOptionsByPlugin?: Record<string, Array<{ value: string; label: string }>>
  selectedAccountByPlugin?: Record<string, string>
  onAccountChange?: (pluginId: string, account: string) => void
}

export function OverviewPage({
  plugins,
  onRetryPlugin,
  displayMode,
  resetTimerDisplayMode,
  onResetTimerDisplayModeToggle,
  accountOptionsByPlugin,
  selectedAccountByPlugin,
  onAccountChange,
}: OverviewPageProps) {
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
          scopeFilter="overview"
          displayMode={displayMode}
          resetTimerDisplayMode={resetTimerDisplayMode}
          onResetTimerDisplayModeToggle={onResetTimerDisplayModeToggle}
          accountOptions={accountOptionsByPlugin?.[plugin.meta.id]}
          selectedAccount={selectedAccountByPlugin?.[plugin.meta.id]}
          onAccountChange={onAccountChange ? (account) => onAccountChange(plugin.meta.id, account) : undefined}
        />
      ))}
    </div>
  )
}
