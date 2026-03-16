import { useEffect } from "react"
import type { UIScale } from "@/lib/settings"

export function useSettingsCompact(uiScale: UIScale) {
  useEffect(() => {
    const root = document.documentElement
    root.classList.remove("small", "compact")
    if (uiScale !== "normal") root.classList.add(uiScale)
  }, [uiScale])
}
