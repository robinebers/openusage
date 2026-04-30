import { ProviderCard } from "@/components/provider-card"
import type { PluginDisplayState } from "@/lib/plugin-types"
import type { DisplayMode, ResetTimerDisplayMode } from "@/lib/settings"

interface ProviderDetailPageProps {
  plugin: PluginDisplayState | null
  planOptions?: { providerId: string; label: string }[]
  onPlanOptionChange?: (providerId: string) => void
  onRetry?: () => void
  displayMode: DisplayMode
  resetTimerDisplayMode: ResetTimerDisplayMode
  onResetTimerDisplayModeToggle?: () => void
  codexMenubarShowAllAccounts?: boolean
  onCodexMenubarShowAllAccountsChange?: (value: boolean) => void
}

export function ProviderDetailPage({
  plugin,
  planOptions,
  onPlanOptionChange,
  onRetry,
  displayMode,
  resetTimerDisplayMode,
  onResetTimerDisplayModeToggle,
  codexMenubarShowAllAccounts = false,
  onCodexMenubarShowAllAccountsChange,
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
      providerId={plugin.sourceProviderId ?? plugin.meta.id}
      plan={plugin.data?.plan}
      planOptions={planOptions}
      onPlanOptionChange={onPlanOptionChange}
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
      onResetTimerDisplayModeToggle={onResetTimerDisplayModeToggle}
      codexMenubarShowAllAccounts={codexMenubarShowAllAccounts}
      onCodexMenubarShowAllAccountsChange={
        plugin.meta.id === "codex" ? onCodexMenubarShowAllAccountsChange : undefined
      }
    />
  )
}
