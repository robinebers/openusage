import { ProviderCard } from "@/components/provider-card"
import type { AccountOption } from "@/hooks/app/use-app-plugin-views"
import type { PluginDisplayState } from "@/lib/plugin-types"
import type { DisplayMode, ResetTimerDisplayMode } from "@/lib/settings"

interface OverviewPageProps {
  plugins: PluginDisplayState[]
  onRetryPlugin?: (pluginId: string) => void
  displayMode: DisplayMode
  resetTimerDisplayMode: ResetTimerDisplayMode
  onResetTimerDisplayModeToggle?: () => void
  codexAccountOptions?: AccountOption[]
  onCodexAccountChange?: (providerId: string) => void
  codexMenubarShowAllAccounts?: boolean
  onCodexMenubarShowAllAccountsChange?: (value: boolean) => void
}

export function OverviewPage({
  plugins,
  onRetryPlugin,
  displayMode,
  resetTimerDisplayMode,
  onResetTimerDisplayModeToggle,
  codexAccountOptions = [],
  onCodexAccountChange,
  codexMenubarShowAllAccounts = false,
  onCodexMenubarShowAllAccountsChange,
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
          providerId={plugin.sourceProviderId ?? plugin.meta.id}
          plan={plugin.data?.plan}
          planOptions={plugin.meta.id === "codex" ? codexAccountOptions : []}
          onPlanOptionChange={onCodexAccountChange}
          codexMenubarShowAllAccounts={codexMenubarShowAllAccounts}
          onCodexMenubarShowAllAccountsChange={
            plugin.meta.id === "codex" ? onCodexMenubarShowAllAccountsChange : undefined
          }
          showSeparator={index < plugins.length - 1}
          loading={plugin.loading}
          error={plugin.error}
          lines={plugin.data?.lines ?? []}
          skeletonLines={plugin.meta.lines}
          lastManualRefreshAt={plugin.lastManualRefreshAt}
          lastUpdatedAt={plugin.lastUpdatedAt}
          onRetry={onRetryPlugin ? () => onRetryPlugin(plugin.sourceProviderId ?? plugin.meta.id) : undefined}
          scopeFilter="overview"
          displayMode={displayMode}
          resetTimerDisplayMode={resetTimerDisplayMode}
          onResetTimerDisplayModeToggle={onResetTimerDisplayModeToggle}
        />
      ))}
    </div>
  )
}
