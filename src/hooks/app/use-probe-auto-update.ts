import { useCallback, useEffect, useState } from "react"
import {
  getEnabledPluginIds,
  type AutoUpdateIntervalMinutes,
  type PluginSettings,
} from "@/lib/settings"

type UseProbeAutoUpdateArgs = {
  pluginSettings: PluginSettings | null
  autoUpdateInterval: AutoUpdateIntervalMinutes
  setLoadingForPlugins: (ids: string[]) => void
  setErrorForPlugins: (ids: string[], error: string) => void
  startBatch: (pluginIds?: string[]) => Promise<string[] | undefined>
}

export function useProbeAutoUpdate({
  pluginSettings,
  autoUpdateInterval,
  setLoadingForPlugins,
  setErrorForPlugins,
  startBatch,
}: UseProbeAutoUpdateArgs) {
  const [autoUpdateNextAt, setAutoUpdateNextAt] = useState<number | null>(null)
  const [autoUpdateResetToken, setAutoUpdateResetToken] = useState(0)

  useEffect(() => {
    if (!pluginSettings) {
      setAutoUpdateNextAt(null)
      return
    }

    const enabledIds = getEnabledPluginIds(pluginSettings)
    if (enabledIds.length === 0) {
      setAutoUpdateNextAt(null)
      return
    }

    const intervalMs = autoUpdateInterval * 60_000
    const scheduleNext = () => setAutoUpdateNextAt(Date.now() + intervalMs)
    scheduleNext()

    const interval = setInterval(() => {
      setLoadingForPlugins(enabledIds)
      startBatch(enabledIds).catch((error) => {
        console.error("Failed to start auto-update batch:", error)
        setErrorForPlugins(enabledIds, "Failed to start probe")
      })
      scheduleNext()
    }, intervalMs)

    return () => clearInterval(interval)
  }, [
    autoUpdateInterval,
    autoUpdateResetToken,
    pluginSettings,
    setLoadingForPlugins,
    setErrorForPlugins,
    startBatch,
  ])

  const resetAutoUpdateSchedule = useCallback(() => {
    if (!pluginSettings) return
    const enabledIds = getEnabledPluginIds(pluginSettings)
    /* v8 ignore start */
    if (enabledIds.length === 0) {
      setAutoUpdateNextAt(null)
      return
    }
    /* v8 ignore stop */

    setAutoUpdateNextAt(Date.now() + autoUpdateInterval * 60_000)
    setAutoUpdateResetToken((value) => value + 1)
  }, [autoUpdateInterval, pluginSettings])

  return {
    autoUpdateNextAt,
    setAutoUpdateNextAt,
    resetAutoUpdateSchedule,
  }
}
