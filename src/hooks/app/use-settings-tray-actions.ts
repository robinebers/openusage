import { useCallback } from "react"

type ScheduleTrayIconUpdate = (reason: "probe" | "settings" | "init", delayMs?: number) => void

type UseSettingsTrayActionsArgs = {
  scheduleTrayIconUpdate: ScheduleTrayIconUpdate
}

export function useSettingsTrayActions({
  scheduleTrayIconUpdate,
}: UseSettingsTrayActionsArgs) {
  const handleTrayIconStyleChange = useCallback((_style: string) => {
    scheduleTrayIconUpdate("settings", 0)
  }, [scheduleTrayIconUpdate])

  const handleTrayShowPercentageChange = useCallback((_value: boolean) => {
    scheduleTrayIconUpdate("settings", 0)
  }, [scheduleTrayIconUpdate])

  return {
    handleTrayIconStyleChange,
    handleTrayShowPercentageChange,
  }
}
