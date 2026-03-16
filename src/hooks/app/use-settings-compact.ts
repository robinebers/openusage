import { useEffect } from "react"

export function useSettingsCompact(compactMode: boolean) {
  useEffect(() => {
    document.documentElement.classList.toggle("compact", compactMode)
  }, [compactMode])
}
