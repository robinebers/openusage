import { useCallback } from "react"
import { invoke } from "@tauri-apps/api/core"
import {
  getEnabledPluginIds,
  saveAlwaysOnTop,
  saveAutoUpdateInterval,
  saveGlobalShortcut,
  saveHideDockIcon,
  saveStartOnLogin,
  type AutoUpdateIntervalMinutes,
  type GlobalShortcut,
  type PluginSettings,
} from "@/lib/settings"

type UseSettingsSystemActionsArgs = {
  pluginSettings: PluginSettings | null
  setAutoUpdateInterval: (value: AutoUpdateIntervalMinutes) => void
  setAutoUpdateNextAt: (value: number | null) => void
  setGlobalShortcut: (value: GlobalShortcut) => void
  setStartOnLogin: (value: boolean) => void
  setHideDockIcon: (value: boolean) => void
  setAlwaysOnTop: (value: boolean) => void
  applyStartOnLogin: (value: boolean) => Promise<void>
}

export function useSettingsSystemActions({
  pluginSettings,
  setAutoUpdateInterval,
  setAutoUpdateNextAt,
  setGlobalShortcut,
  setStartOnLogin,
  setHideDockIcon,
  setAlwaysOnTop,
  applyStartOnLogin,
}: UseSettingsSystemActionsArgs) {
  const handleAutoUpdateIntervalChange = useCallback((value: AutoUpdateIntervalMinutes) => {
    setAutoUpdateInterval(value)

    if (pluginSettings) {
      const enabledIds = getEnabledPluginIds(pluginSettings)
      if (enabledIds.length > 0) {
        setAutoUpdateNextAt(Date.now() + value * 60_000)
      } else {
        setAutoUpdateNextAt(null)
      }
    }

    void saveAutoUpdateInterval(value).catch((error) => {
      console.error("Failed to save auto-update interval:", error)
    })
  }, [pluginSettings, setAutoUpdateInterval, setAutoUpdateNextAt])

  const handleGlobalShortcutChange = useCallback((value: GlobalShortcut) => {
    setGlobalShortcut(value)
    void saveGlobalShortcut(value).catch((error) => {
      console.error("Failed to save global shortcut:", error)
    })
    invoke("update_global_shortcut", { shortcut: value }).catch((error) => {
      console.error("Failed to update global shortcut:", error)
    })
  }, [setGlobalShortcut])

  const handleStartOnLoginChange = useCallback((value: boolean) => {
    setStartOnLogin(value)
    void saveStartOnLogin(value).catch((error) => {
      console.error("Failed to save start on login:", error)
    })
    void applyStartOnLogin(value).catch((error) => {
      console.error("Failed to update start on login:", error)
    })
  }, [applyStartOnLogin, setStartOnLogin])

  const handleHideDockIconChange = useCallback((value: boolean) => {
    setHideDockIcon(value)
    void saveHideDockIcon(value).catch((error) => {
      console.error("Failed to save hide dock icon setting:", error)
    })
    invoke("update_dock_icon_visibility", { hidden: value }).catch((error) => {
      console.error("Failed to update dock icon visibility:", error)
    })
  }, [setHideDockIcon])

  const handleAlwaysOnTopChange = useCallback((value: boolean) => {
    setAlwaysOnTop(value)
    void saveAlwaysOnTop(value).catch((error) => {
      console.error("Failed to save always on top setting:", error)
    })
    invoke("update_always_on_top", { enabled: value }).catch((error) => {
      console.error("Failed to update always on top:", error)
    })
  }, [setAlwaysOnTop])

  return {
    handleAutoUpdateIntervalChange,
    handleGlobalShortcutChange,
    handleStartOnLoginChange,
    handleHideDockIconChange,
    handleAlwaysOnTopChange,
  }
}
