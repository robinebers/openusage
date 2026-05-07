import { useCallback } from "react"
import {
  saveDisplayMode,
  saveMenubarIconStyle,
  saveResetTimerDisplayMode,
  saveThemeMode,
  saveUsageAlertCustomThreshold,
  saveUsageAlertEnabled,
  saveUsageAlertSound,
  saveUsageAlertThreshold,
  type DisplayMode,
  type MenubarIconStyle,
  type ResetTimerDisplayMode,
  type ThemeMode,
  type UsageAlertSound,
  type UsageAlertThreshold,
} from "@/lib/settings"

type ScheduleTrayIconUpdate = (reason: "probe" | "settings" | "init", delayMs?: number) => void

type UseSettingsDisplayActionsArgs = {
  setThemeMode: (value: ThemeMode) => void
  setDisplayMode: (value: DisplayMode) => void
  resetTimerDisplayMode: ResetTimerDisplayMode
  setResetTimerDisplayMode: (value: ResetTimerDisplayMode) => void
  setMenubarIconStyle: (value: MenubarIconStyle) => void
  setUsageAlertEnabled: (value: boolean) => void
  setUsageAlertThreshold: (value: UsageAlertThreshold) => void
  setCustomUsageAlertThreshold: (value: number | null) => void
  setUsageAlertSound: (value: UsageAlertSound) => void
  scheduleTrayIconUpdate: ScheduleTrayIconUpdate
}

export function useSettingsDisplayActions({
  setThemeMode,
  setDisplayMode,
  resetTimerDisplayMode,
  setResetTimerDisplayMode,
  setMenubarIconStyle,
  setUsageAlertEnabled,
  setUsageAlertThreshold,
  setCustomUsageAlertThreshold,
  setUsageAlertSound,
  scheduleTrayIconUpdate,
}: UseSettingsDisplayActionsArgs) {
  const handleThemeModeChange = useCallback((mode: ThemeMode) => {
    setThemeMode(mode)
    void saveThemeMode(mode).catch((error) => {
      console.error("Failed to save theme mode:", error)
    })
  }, [setThemeMode])

  const handleDisplayModeChange = useCallback((mode: DisplayMode) => {
    setDisplayMode(mode)
    scheduleTrayIconUpdate("settings", 0)
    void saveDisplayMode(mode).catch((error) => {
      console.error("Failed to save display mode:", error)
    })
  }, [scheduleTrayIconUpdate, setDisplayMode])

  const handleResetTimerDisplayModeChange = useCallback((mode: ResetTimerDisplayMode) => {
    setResetTimerDisplayMode(mode)
    void saveResetTimerDisplayMode(mode).catch((error) => {
      console.error("Failed to save reset timer display mode:", error)
    })
  }, [setResetTimerDisplayMode])

  const handleResetTimerDisplayModeToggle = useCallback(() => {
    const next = resetTimerDisplayMode === "relative" ? "absolute" : "relative"
    handleResetTimerDisplayModeChange(next)
  }, [handleResetTimerDisplayModeChange, resetTimerDisplayMode])

  const handleMenubarIconStyleChange = useCallback((style: MenubarIconStyle) => {
    setMenubarIconStyle(style)
    scheduleTrayIconUpdate("settings", 0)
    void saveMenubarIconStyle(style).catch((error) => {
      console.error("Failed to save menubar icon style:", error)
    })
  }, [scheduleTrayIconUpdate, setMenubarIconStyle])

  const handleUsageAlertEnabledChange = useCallback((value: boolean) => {
    track("setting_changed", { setting: "usage_alert_enabled", value: value ? "true" : "false" })
    setUsageAlertEnabled(value)
    void saveUsageAlertEnabled(value).catch((error) => {
      console.error("Failed to save usage alert enabled:", error)
    })
  }, [setUsageAlertEnabled])

  const handleUsageAlertThresholdChange = useCallback((value: UsageAlertThreshold) => {
    track("setting_changed", { setting: "usage_alert_threshold", value: String(value) })
    setUsageAlertThreshold(value)
    void saveUsageAlertThreshold(value).catch((error) => {
      console.error("Failed to save usage alert threshold:", error)
    })
  }, [setUsageAlertThreshold])

  const handleUsageAlertCustomThresholdChange = useCallback((value: number | null) => {
    setCustomUsageAlertThreshold(value)
    void saveUsageAlertCustomThreshold(value).catch((error) => {
      console.error("Failed to save usage alert custom threshold:", error)
    })
  }, [setCustomUsageAlertThreshold])

  const handleUsageAlertSoundChange = useCallback((value: UsageAlertSound) => {
    track("setting_changed", { setting: "usage_alert_sound", value })
    setUsageAlertSound(value)
    void saveUsageAlertSound(value).catch((error) => {
      console.error("Failed to save usage alert sound:", error)
    })
  }, [setUsageAlertSound])

  return {
    handleThemeModeChange,
    handleDisplayModeChange,
    handleResetTimerDisplayModeChange,
    handleResetTimerDisplayModeToggle,
    handleMenubarIconStyleChange,
    handleUsageAlertEnabledChange,
    handleUsageAlertThresholdChange,
    handleUsageAlertCustomThresholdChange,
    handleUsageAlertSoundChange,
  }
}
