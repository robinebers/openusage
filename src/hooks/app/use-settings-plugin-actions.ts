import { useCallback } from "react"
import { track } from "@/lib/analytics"
import { savePluginSettings, type PluginSettings } from "@/lib/settings"

const TRAY_SETTINGS_DEBOUNCE_MS = 2000

type ScheduleTrayIconUpdate = (reason: "probe" | "settings" | "init", delayMs?: number) => void

type UseSettingsPluginActionsArgs = {
  pluginSettings: PluginSettings | null
  setPluginSettings: (value: PluginSettings | null) => void
  setLoadingForPlugins: (ids: string[]) => void
  setErrorForPlugins: (ids: string[], error: string) => void
  startBatch: (pluginIds?: string[]) => Promise<string[] | undefined>
  scheduleTrayIconUpdate: ScheduleTrayIconUpdate
}

export function useSettingsPluginActions({
  pluginSettings,
  setPluginSettings,
  setLoadingForPlugins,
  setErrorForPlugins,
  startBatch,
  scheduleTrayIconUpdate,
}: UseSettingsPluginActionsArgs) {
  const handleReorder = useCallback((orderedIds: string[]) => {
    if (!pluginSettings) return
    track("providers_reordered", { count: orderedIds.length })
    const nextSettings: PluginSettings = {
      ...pluginSettings,
      order: orderedIds,
    }
    setPluginSettings(nextSettings)
    scheduleTrayIconUpdate("settings", TRAY_SETTINGS_DEBOUNCE_MS)
    void savePluginSettings(nextSettings).catch((error) => {
      console.error("Failed to save plugin order:", error)
    })
  }, [pluginSettings, scheduleTrayIconUpdate, setPluginSettings])

  const handleToggle = useCallback((id: string) => {
    if (!pluginSettings) return
    const wasDisabled = pluginSettings.disabled.includes(id)
    track("provider_toggled", { provider_id: id, enabled: wasDisabled ? "true" : "false" })
    const disabled = new Set(pluginSettings.disabled)

    if (wasDisabled) {
      disabled.delete(id)
      setLoadingForPlugins([id])
      startBatch([id]).catch((error) => {
        console.error("Failed to start probe for enabled plugin:", error)
        setErrorForPlugins([id], "Failed to start probe")
      })
    } else {
      disabled.add(id)
    }

    const nextSettings: PluginSettings = {
      ...pluginSettings,
      disabled: Array.from(disabled),
    }
    setPluginSettings(nextSettings)
    scheduleTrayIconUpdate("settings", TRAY_SETTINGS_DEBOUNCE_MS)
    void savePluginSettings(nextSettings).catch((error) => {
      console.error("Failed to save plugin toggle:", error)
    })
  }, [
    pluginSettings,
    scheduleTrayIconUpdate,
    setErrorForPlugins,
    setLoadingForPlugins,
    setPluginSettings,
    startBatch,
  ])

  const handleTrayLineToggle = useCallback((id: string, lineLabel: string, checked: boolean, fallback?: string) => {
    if (!pluginSettings) return
    const prevTrayLines = pluginSettings.trayLines || {}
    let currentLinesForPlugin = prevTrayLines[id] || []

    if (currentLinesForPlugin.length === 0 && fallback) {
      currentLinesForPlugin = [fallback]
    }

    let nextLinesForPlugin: string[]
    if (checked) {
      if (!currentLinesForPlugin.includes(lineLabel)) {
        nextLinesForPlugin = [...currentLinesForPlugin, lineLabel]
      } else {
        nextLinesForPlugin = currentLinesForPlugin
      }
    } else {
      nextLinesForPlugin = currentLinesForPlugin.filter(l => l !== lineLabel)
    }

    const nextTrayLines = {
      ...prevTrayLines,
      [id]: nextLinesForPlugin,
    }

    // Clean up empty arrays to keep state minimal
    if (nextLinesForPlugin.length === 0) {
      delete nextTrayLines[id]
    }

    const nextSettings: PluginSettings = {
      ...pluginSettings,
      trayLines: nextTrayLines,
    }
    setPluginSettings(nextSettings)
    scheduleTrayIconUpdate("settings", TRAY_SETTINGS_DEBOUNCE_MS)
    void savePluginSettings(nextSettings).catch((error) => {
      console.error("Failed to save tray line toggle:", error)
    })
  }, [
    pluginSettings,
    scheduleTrayIconUpdate,
    setPluginSettings,
  ])

  return {
    handleReorder,
    handleToggle,
    handleTrayLineToggle,
  }
}
