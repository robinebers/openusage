import { useEffect } from "react"
import type { UIScale } from "@/lib/settings"

export function useSettingsUIScale(uiScale: UIScale) {
  useEffect(() => {
    const root = document.documentElement
    root.classList.remove("small", "compact")
    if (uiScale !== "normal") root.classList.add(uiScale)
  }, [uiScale])
}
