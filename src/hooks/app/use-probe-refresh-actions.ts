import { useCallback } from "react"
import type { MutableRefObject } from "react"
import { track } from "@/lib/analytics"
import { REFRESH_COOLDOWN_MS, getEnabledPluginIds, type PluginSettings } from "@/lib/settings"
import type { PluginState } from "@/hooks/app/types"

type UseProbeRefreshActionsArgs = {
  pluginSettings: PluginSettings | null
  pluginStatesRef: MutableRefObject<Record<string, PluginState>>
  manualRefreshIdsRef: MutableRefObject<Set<string>>
  resetAutoUpdateSchedule: () => void
  setLoadingForPlugins: (ids: string[]) => void
  setErrorForPlugins: (ids: string[], error: string) => void
  startBatch: (pluginIds?: string[]) => Promise<string[] | undefined>
}

export function useProbeRefreshActions({
  pluginSettings,
  pluginStatesRef,
  manualRefreshIdsRef,
  resetAutoUpdateSchedule,
  setLoadingForPlugins,
  setErrorForPlugins,
  startBatch,
}: UseProbeRefreshActionsArgs) {
  const startManualRefresh = useCallback(
    (ids: string[], errorMessage: string) => {
      for (const id of ids) {
        manualRefreshIdsRef.current.add(id)
      }

      setLoadingForPlugins(ids)
      startBatch(ids).catch((error) => {
        for (const id of ids) {
          manualRefreshIdsRef.current.delete(id)
        }
        console.error(errorMessage, error)
        setErrorForPlugins(ids, "Failed to start probe")
      })
    },
    [manualRefreshIdsRef, setLoadingForPlugins, setErrorForPlugins, startBatch]
  )

  const handleRetryPlugin = useCallback(
    (id: string) => {
      const currentState = pluginStatesRef.current[id]
      if (currentState?.loading) return
      if (manualRefreshIdsRef.current.has(id)) return
      const lastManualRefreshAt = currentState?.lastManualRefreshAt
      if (lastManualRefreshAt && Date.now() - lastManualRefreshAt < REFRESH_COOLDOWN_MS) return

      track("provider_refreshed", { provider_id: id })
      resetAutoUpdateSchedule()
      startManualRefresh([id], "Failed to retry plugin:")
    },
    [manualRefreshIdsRef, pluginStatesRef, resetAutoUpdateSchedule, startManualRefresh]
  )

  const handleRefreshAll = useCallback(() => {
    if (!pluginSettings) return
    const enabledIds = getEnabledPluginIds(pluginSettings)
    if (enabledIds.length === 0) return

    const now = Date.now()
    const eligibleIds = enabledIds.filter((id) => {
      const currentState = pluginStatesRef.current[id]
      if (currentState?.loading) return false
      if (manualRefreshIdsRef.current.has(id)) return false
      const lastManualRefreshAt = currentState?.lastManualRefreshAt
      if (!lastManualRefreshAt) return true
      return now - lastManualRefreshAt >= REFRESH_COOLDOWN_MS
    })
    if (eligibleIds.length === 0) return

    resetAutoUpdateSchedule()
    startManualRefresh(eligibleIds, "Failed to start refresh batch:")
  }, [pluginSettings, pluginStatesRef, manualRefreshIdsRef, resetAutoUpdateSchedule, startManualRefresh])

  return {
    handleRetryPlugin,
    handleRefreshAll,
  }
}
