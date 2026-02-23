import { useCallback } from "react"
import { track } from "@/lib/analytics"
import {
  isTrayPercentageMandatory,
  saveTrayIconStyle,
  saveTrayShowPercentage,
  type TrayIconStyle,
} from "@/lib/settings"

type ScheduleTrayIconUpdate = (reason: "probe" | "settings" | "init", delayMs?: number) => void

type UseSettingsTrayActionsArgs = {
  setTrayIconStyle: (value: TrayIconStyle) => void
  trayShowPercentage: boolean
  setTrayShowPercentage: (value: boolean) => void
  scheduleTrayIconUpdate: ScheduleTrayIconUpdate
}

export function useSettingsTrayActions({
  setTrayIconStyle,
  trayShowPercentage,
  setTrayShowPercentage,
  scheduleTrayIconUpdate,
}: UseSettingsTrayActionsArgs) {
  const handleTrayIconStyleChange = useCallback((style: TrayIconStyle) => {
    track("setting_changed", { setting: "tray_icon_style", value: style })
    const mandatory = isTrayPercentageMandatory(style)
    if (mandatory && trayShowPercentage !== true) {
      setTrayShowPercentage(true)
      void saveTrayShowPercentage(true).catch((error) => {
        console.error("Failed to save tray show percentage:", error)
      })
    }

    setTrayIconStyle(style)
    scheduleTrayIconUpdate("settings", 0)
    void saveTrayIconStyle(style).catch((error) => {
      console.error("Failed to save tray icon style:", error)
    })
  }, [scheduleTrayIconUpdate, setTrayIconStyle, setTrayShowPercentage, trayShowPercentage])

  const handleTrayShowPercentageChange = useCallback((value: boolean) => {
    track("setting_changed", { setting: "tray_show_percentage", value: value ? "true" : "false" })
    setTrayShowPercentage(value)
    scheduleTrayIconUpdate("settings", 0)
    void saveTrayShowPercentage(value).catch((error) => {
      console.error("Failed to save tray show percentage:", error)
    })
  }, [scheduleTrayIconUpdate, setTrayShowPercentage])

  return {
    handleTrayIconStyleChange,
    handleTrayShowPercentageChange,
  }
}
